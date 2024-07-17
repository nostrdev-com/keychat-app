import 'package:app/controller/home.controller.dart';
import 'package:app/models/embedded/cashu_info.dart';
import 'package:app/models/embedded/relay_file_fee.dart';
import 'package:app/models/embedded/relay_message_fee.dart';
import 'package:app/models/message_bill.dart';
import 'package:app/models/relay.dart';
import 'package:app/nostr-core/nostr.dart';
import 'package:app/nostr-core/nostr_event.dart';
import 'package:app/nostr-core/nostr_nip4_req.dart';
import 'package:app/nostr-core/relay_event_status.dart';
import 'package:app/nostr-core/relay_websocket.dart';
import 'package:app/service/message.service.dart';
import 'package:app/service/relay.service.dart';
import 'package:app/service/storage.dart';
import 'package:app/utils.dart';
import 'package:easy_debounce/easy_debounce.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:keychat_ecash/keychat_ecash.dart';
import 'package:websocket_universal/websocket_universal.dart';

import '../utils.dart' as utils;

class WebsocketService extends GetxService {
  RelayService rs = RelayService();

  RxString relayStatusInt = RelayStatusEnum.init.name.obs;
  final RxMap<String, RelayWebsocket> channels = <String, RelayWebsocket>{}.obs;
  final RxMap<String, RelayMessageFee> relayMessageFeeModels =
      <String, RelayMessageFee>{}.obs;
  Map<String, RelayFileFee> relayFileFeeModels = {};

  DateTime initAt = DateTime.now();

  @override
  void onReady() {
    super.onReady();
    localFeesConfigFromLocalStorage();
    RelayService().initRelayFeeInfo();
  }

  int activitySocketCount() {
    return channels.values
        .where((element) => element.channelStatus == RelayStatusEnum.success)
        .length;
  }

  // new a websocket channel for this relay
  Future addChannel(Relay relay, [List<String> pubkeys = const []]) async {
    RelayWebsocket rw = RelayWebsocket(relay);
    channels[relay.url] = rw;
    if (!relay.active) {
      return;
    }

    rw = await _startConnectRelay(rw);
    if (pubkeys.isNotEmpty) {
      DateTime since = await MessageService().getNostrListenStartAt(relay.url);
      rw.startListen(pubkeys, since);
    }
  }

  void checkOnlineAndConnect() async {
    for (RelayWebsocket rw in channels.values) {
      var status = await rw.checkOnlineStatus();
      if (!status) {
        _startConnectRelay(rw);
      }
    }
  }

  deleteRelay(Relay value) {
    if (channels[value.url] != null) {
      channels[value.url]!.channel?.disconnect('goingAway');
      channels[value.url]!.channel?.close();
    }
    channels.remove(value.url);
  }

  List<String> getActiveRelayString() {
    List<String> res = [];
    for (RelayWebsocket rw in channels.values) {
      if (rw.relay.active) {
        res.add(rw.relay.url);
      }
    }
    return res;
  }

  List<String> getOnlineRelayString() {
    List<String> res = [];
    for (RelayWebsocket rw in channels.values) {
      if (rw.channel != null && rw.channelStatus == RelayStatusEnum.success) {
        res.add(rw.relay.url);
      }
    }
    return res;
  }

  Future<WebsocketService> init() async {
    relayStatusInt.value = RelayStatusEnum.connecting.name;
    List<Relay> list = await rs.initRelay();
    start(list);
    return this;
  }

  listenPubkey(List<String> pubkeys,
      {DateTime? since, String? relay, int? limit}) async {
    if (pubkeys.isEmpty) return;

    since ??= DateTime.now().subtract(const Duration(days: 7));
    String subId = utils.generate64RandomHexChars(16);

    NostrNip4Req req = NostrNip4Req(
        reqId: subId, pubkeys: pubkeys, since: since, limit: limit);

    Get.find<WebsocketService>().sendReq(req, relay);
  }

  sendRawReq(String msg, [String? relay]) {
    if (relay != null && channels[relay] != null) {
      return channels[relay]!.sendRawREQ(msg);
    }
    for (RelayWebsocket rw in channels.values) {
      rw.sendRawREQ(msg);
    }
  }

  sendReq(NostrNip4Req nostrReq, [String? relay]) {
    if (relay != null && channels[relay] != null) {
      return channels[relay]!.sendREQ(nostrReq);
    }
    int sent = 0;
    for (RelayWebsocket rw in channels.values) {
      if (rw.channelStatus != RelayStatusEnum.success || rw.channel == null) {
        continue;
      }
      sent++;
      rw.sendREQ(nostrReq);
    }
    if (sent == 0) throw Exception('Not connected with relay server');
  }

  setChannelStatus(String relay, RelayStatusEnum status,
      [String? errorMessage]) {
    channels[relay]?.channelStatus = status;
    if (channels[relay] != null) {
      channels[relay]!.relay.errorMessage = errorMessage;
    }
    channels.refresh();
    int success = 0;
    for (var rw in channels.values) {
      if (rw.channelStatus == RelayStatusEnum.success) {
        ++success;
      }
    }
    if (success > 0) {
      if (relayStatusInt.value != RelayStatusEnum.success.name) {
        relayStatusInt.value = RelayStatusEnum.success.name;
        EasyDebounce.debounce('loadRoomList', const Duration(seconds: 1),
            () => Get.find<HomeController>().loadRoomList());
      }

      return;
    }
    if (success == 0) {
      int diff =
          DateTime.now().millisecondsSinceEpoch - initAt.millisecondsSinceEpoch;
      if (diff > 1000) {
        relayStatusInt.value = RelayStatusEnum.allFailed.name;
        return;
      }
    }
    relayStatusInt.value = RelayStatusEnum.connecting.name;
  }

  start([List<Relay>? list]) {
    EasyThrottle.throttle('startConnectWebsocket', const Duration(seconds: 2),
        () async {
      initAt = DateTime.now();
      WriteEventStatus.clear();
      await stopListening();
      list ??= await RelayService().list();
      await _createChannels(list ?? []);
    });
  }

  Future stopListening() async {
    for (RelayWebsocket rw in channels.values) {
      rw.channel?.disconnect('goingAway');
      rw.channel?.close();
    }
    channels.clear();
  }

  removePubkeyFromSubscription(String pubkey) {
    for (RelayWebsocket rw in channels.values) {
      for (var entry in rw.subscriptions.entries) {
        if (entry.value.contains(pubkey)) {
          rw.subscriptions[entry.key]?.remove(pubkey);
          break;
        }
      }
    }
  }

  void updateRelayWidget(Relay value) {
    if (channels[value.url] != null) {
      if (!value.active) {
        channels[value.url]!.channelStatus = RelayStatusEnum.noAcitveRelay;
      }
      channels[value.url]!.relay = value;
      channels.refresh();
    } else {
      addChannel(value);
    }
  }

  Future<List<String>> writeNostrEvent(
      {required NostrEventModel event,
      required String encryptedEvent,
      required int roomId,
      String? hisRelay,
      Function(bool)? sentCallback}) async {
    List<String> relays = getOnlineRelayString();
    // set his relay
    if (hisRelay != null && hisRelay.isNotEmpty) {
      relays = [];
      if (channels[hisRelay] != null) {
        if (channels[hisRelay]!.channelStatus == RelayStatusEnum.success) {
          relays = [hisRelay];
        }
      }
    }
    if (relays.isEmpty) {
      throw Exception('His relay not connected');
    }

    // listen status
    WriteEventStatus.addSubscripton(event.id, relays.length,
        sentCallback: sentCallback);

    List<Future> tasks = [];
    List<String> successRelay = [];
    String toSendMesage = "[\"EVENT\",$encryptedEvent]";
    for (String relay in relays) {
      tasks.add(() async {
        String eventRaw =
            await _addCashuToMessage(toSendMesage, relay, roomId, event.id);
        if (channels[relay]?.channel != null) {
          logger.i(
              'to:[$relay]: ${eventRaw.length > 200 ? eventRaw.substring(0, 400) : eventRaw}'); //
          channels[relay]!.channel!.sendMessage(eventRaw);
          successRelay.add(relay);
        } else {
          logger.e('====to:[$relay]: NOT_AVAILABLE =====');
        }
      }());
    }
    List<Exception> errors = [];
    Future.wait(tasks).then((res) {}).catchError((e, s) {
      errors.add(e);
      logger.e('writeNostrEvent error', error: e, stackTrace: s);
    }, test: (e) => true).whenComplete(() {
      if (successRelay.isEmpty) {
        String messages = errors
            .map((item) => Utils.getErrorMessage(item))
            .toList()
            .join(',');
        Get.snackbar('Message Send Failed', messages,
            icon: const Icon(Icons.error));
      }
    });
    return relays;
  }

  Future<String> _addCashuToMessage(
      String message, String relay, int roomId, String eventId) async {
    RelayMessageFee? payInfoModel = relayMessageFeeModels[relay];
    if (payInfoModel == null) return message;
    if (payInfoModel.amount == 0) return message;
    CashuInfoModel? cashuA;

    cashuA = await CashuUtil.getCashuA(
        amount: payInfoModel.amount,
        token: payInfoModel.unit.name,
        mints: payInfoModel.mints);

    message = message.substring(0, message.length - 1);
    message += ',"${cashuA.token}"]';
    double amount = (payInfoModel.amount).toDouble();

    MessageBill mb = MessageBill(
        eventId: eventId,
        roomId: roomId,
        amount: amount,
        relay: relay,
        createdAt: DateTime.now(),
        cashuA: cashuA.token);
    MessageService().insertMessageBill(mb);
    return message;
  }

  Future _createChannels(List<Relay> list) async {
    list = list.where((element) => element.url.isNotEmpty).toList();
    for (Relay relay in list) {
      try {
        RelayWebsocket rw = RelayWebsocket(relay);
        channels[relay.url] = rw;

        await _startConnectRelay(rw);
      } catch (e, s) {
        logger.e(e.toString(), error: e, stackTrace: s);
      }
    }
  }

  Future<RelayWebsocket> _startConnectRelay(RelayWebsocket rw) async {
    Relay relay = rw.relay;
    if (!relay.active) {
      // skip inactive relay
      return rw;
    }

    if (rw.failedTimes > 3) {
      rw.channelStatus = RelayStatusEnum.failed;
      return rw;
    }

    loggerNoLine.i('start connect ${relay.url}');
    SocketConnectionOptions connectionOptions = SocketConnectionOptions(
        timeoutConnectionMs: 6000,
        failedReconnectionAttemptsLimit: GetPlatform.isMacOS ? 999 : 5,
        reconnectionDelay: GetPlatform.isMacOS
            ? const Duration(seconds: 5)
            : const Duration(seconds: 2),
        pingRestrictionForce: true); // disable ping

    final IMessageProcessor<String, String> textSocketProcessor =
        SocketSimpleTextProcessor();
    IWebSocketHandler textSocketHandler =
        IWebSocketHandler<String, String>.createClient(
      relay.url,
      textSocketProcessor,
      connectionOptions: connectionOptions,
    );
    rw.channel = textSocketHandler;
    textSocketHandler.socketHandlerStateStream.listen((stateEvent) {
      loggerNoLine.i('[${relay.url}] status: ${stateEvent.status}');

      switch (stateEvent.status) {
        case SocketStatus.connected:
          rw.connectSuccess(textSocketHandler);

          break;
        case SocketStatus.connecting:
          if (rw.channelStatus != RelayStatusEnum.connecting) {
            rw.connecting();
          }
          break;
        case SocketStatus.disconnected:
          if (rw.channelStatus != RelayStatusEnum.failed) {
            rw.disconnected();
          }
          break;
        default:
      }
    });
    NostrAPI nostrAPI = NostrAPI();
    textSocketHandler.incomingMessagesStream.listen((inMsg) {
      nostrAPI.processWebsocketMessage(relay, inMsg);
    });

    final isTextSocketConnected = await textSocketHandler.connect();
    if (!isTextSocketConnected) {
      logger.e('Connection to [${relay.url}] failed for some reason!');
      rw.disconnected();
    }

    return rw;
  }

  bool existFreeRelay() {
    for (var channel in channels.entries) {
      if (channel.value.channelStatus == RelayStatusEnum.success) {
        if (relayMessageFeeModels[channel.key]?.amount == 0) {
          return true;
        }
      }
    }
    return false;
  }

  Future localFeesConfigFromLocalStorage() async {
    Map map1 = await Storage.getLocalStorageMap(
        StorageKeyString.relayMessageFeeConfig);
    for (var entry in map1.entries) {
      if (entry.value.keys.length > 0) {
        relayMessageFeeModels[entry.key] =
            RelayMessageFee.fromJson(entry.value);
      }
    }

    Map map2 =
        await Storage.getLocalStorageMap(StorageKeyString.relayFileFeeConfig);
    for (var entry in map2.entries) {
      if (entry.value.keys.length > 0) {
        relayFileFeeModels[entry.key] = RelayFileFee.fromJson(entry.value);
      }
    }
  }
}
