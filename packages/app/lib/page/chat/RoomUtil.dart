import 'dart:convert' show jsonDecode;
import 'package:app/global.dart';
import 'package:app/models/contact.dart';
import 'package:app/models/event_log.dart';
import 'package:app/models/identity.dart';
import 'package:app/models/keychat/qrcode_user_model.dart';
import 'package:app/page/chat/ChatMediaFilesPage.dart';
import 'package:app/page/chat/contact_page.dart';
import 'package:keychat_rust_ffi_plugin/api_cashu.dart' as rustCashu;
import 'package:keychat_rust_ffi_plugin/api_nostr.dart' as rustNostr;

import 'package:app/service/contact.service.dart';
import 'package:app/service/storage.dart';

import 'package:app/controller/chat.controller.dart';
import 'package:app/controller/home.controller.dart';
import 'package:app/models/db_provider.dart';
import 'package:app/models/embedded/msg_file_info.dart';

import 'package:app/models/message.dart';
import 'package:app/models/message_bill.dart';
import 'package:app/models/room.dart';
import 'package:app/page/components.dart';
import 'package:app/page/widgets/image_min_preview_widget.dart';
import 'package:app/service/file_util.dart';
import 'package:app/service/notify.service.dart';
import 'package:app/service/room.service.dart';
import 'package:app/utils.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:get/get.dart';
import 'package:isar/isar.dart';
import 'package:keychat_rust_ffi_plugin/api_cashu/types.dart';
import 'package:settings_ui/settings_ui.dart';

class RoomUtil {
  static String getHelloMessage(String name) {
    return '''
😄 Hi, I'm $name.
Let's start an encrypted chat.''';
  }

  // auto to delete messages and event logs
  static Future executeAutoDelete() async {
    // delete nostr event log
    await DBProvider.database.writeTxn(() async {
      await DBProvider.database.eventLogs
          .filter()
          .createdAtLessThan(DateTime.now().subtract(const Duration(days: 30)))
          .deleteAll();
    });
    // excute auto delete message by user setting
    int timestamp =
        await Storage.getIntOrZero(StorageKeyString.autoDeleteMessageDays);
    if (timestamp > 0 &&
        DateTime.now()
                .difference(DateTime.fromMillisecondsSinceEpoch(timestamp))
                .inDays <
            1) {
      logger.i('auto_delete_message been executed today. Skip');
      return;
    }
    await Storage.setInt(StorageKeyString.autoDeleteMessageDays,
        DateTime.now().millisecondsSinceEpoch);
    logger.i('The auto tasks been executed');
    List<Room> list = await DBProvider.database.rooms
        .filter()
        .autoDeleteDaysGreaterThan(0)
        .findAll();
    for (Room room in list) {
      await RoomUtil.excuteAutoDeleteRoomMessages(
          room.identityId, room.id, room.autoDeleteDays);
    }

    // room setting > global setting
    DateTime fromAt = DateTime.now().subtract(const Duration(days: 180));
    var start = BigInt.from(fromAt.millisecondsSinceEpoch);
    rustCashu.removeTransactions(
        unixTimestampMsLe: start, kind: TransactionStatus.success);
    rustCashu.removeTransactions(
        unixTimestampMsLe: start, kind: TransactionStatus.expired);
    rustCashu.removeTransactions(
        unixTimestampMsLe: start, kind: TransactionStatus.failed);
  }

  static Future excuteAutoDeleteRoomMessages(
      int identityId, int roomId, int days) async {
    if (days <= 0) return;
    DateTime fromAt = DateTime.now().subtract(Duration(days: days));

    Isar database = DBProvider.database;
    await database.writeTxn(() async {
      await database.messages
          .filter()
          .roomIdEqualTo(roomId)
          .createdAtLessThan(fromAt)
          .deleteAll();
      await database.messageBills
          .filter()
          .roomIdEqualTo(roomId)
          .createdAtLessThan(fromAt)
          .deleteAll();
    });

    String dir =
        await FileUtils.getRoomFolder(identityId: identityId, roomId: roomId);
    FileUtils.deleteFilesByTime(dir, fromAt);
  }

  static SettingsTile autoCleanMessage(ChatController cc) {
    autoDeleteHandle(int day) {
      cc.roomObs.value.autoDeleteDays = day;
      RoomService().updateRoom(cc.roomObs.value);
      cc.roomObs.refresh();
      EasyLoading.showSuccess('Saved');
      if (day > 0) {
        excuteAutoDeleteRoomMessages(
                cc.roomObs.value.identityId, cc.roomObs.value.id, day)
            .then((value) => cc.loadAllChat());
      }
    }

    return SettingsTile.navigation(
        leading: const Icon(
          CupertinoIcons.calendar,
        ),
        title: const Text("Auto Delete Messages"),
        value: Text(Utils.getDaysText(cc.roomObs.value.autoDeleteDays)),
        onPressed: (context) {
          showModalBottomSheetWidget(
              context,
              'Auto Delete Messages',
              Obx(() => SettingsList(platform: DevicePlatform.iOS, sections: [
                    SettingsSection(
                        title: const Text(
                            'Messages will been deleted before days'),
                        tiles: [0, 1, 7, 30, 90]
                            .map(
                              (e) => SettingsTile(
                                onPressed: (context) {
                                  autoDeleteHandle(e);
                                },
                                title: Text(Utils.getDaysText(e)),
                                trailing: cc.roomObs.value.autoDeleteDays == e
                                    ? const Icon(
                                        Icons.done,
                                        color: Colors.green,
                                      )
                                    : null,
                              ),
                            )
                            .toList())
                  ])));
        });
  }

  static SettingsTile pinRoomSection(ChatController chatController) {
    return SettingsTile.switchTile(
      initialValue: chatController.roomObs.value.pin,
      leading: const Icon(
        CupertinoIcons.pin,
      ),
      title: const Text('Sticky on Top'),
      onToggle: (value) async {
        chatController.roomObs.value.pin = value;
        chatController.roomObs.value.pinAt = DateTime.now();
        await RoomService().updateRoom(chatController.roomObs.value);
        chatController.roomObs.refresh();
        EasyLoading.showSuccess('Saved');
        await Get.find<HomeController>()
            .loadIdentityRoomList(chatController.roomObs.value.identityId);
      },
    );
  }

  static SettingsTile muteSection(ChatController chatController) {
    return SettingsTile.switchTile(
      initialValue: chatController.roomObs.value.isMute,
      leading: const Icon(
        Icons.notifications_none,
      ),
      title: const Text('Mute Notifications'),
      description: const Text(
          'If muted, receive pubkey will not be uploaded to the notification server and metadata will be protected'),
      onToggle: (value) async {
        Room room = chatController.roomObs.value;
        List<String> pubkeys = [];

        if (room.type == RoomType.group) {
          pubkeys.add(room.mykey.value!.pubkey);
        } else {
          List<String>? data = ContactService().getMyReceiveKeys(room);
          if (data != null) pubkeys.addAll(data);
        }
        bool res = false;
        if (value) {
          res = await NotifyService.removePubkeys(pubkeys);
        } else {
          res = await NotifyService.addPubkeys(pubkeys);
        }
        if (!res) {
          EasyLoading.showError('Failed, Please try again');
          return;
        }
        if (room.type == RoomType.common) {
          await ContactService().updateReceiveKeyIsMute(room, value);
        }
        chatController.roomObs.value.isMute = value;
        await RoomService().updateRoom(chatController.roomObs.value);
        chatController.roomObs.refresh();
        EasyLoading.showSuccess('Saved');
        await Get.find<HomeController>().loadIdentityRoomList(room.identityId);
      },
    );
  }

  static Widget? getSubtitleDisplay(Room room, DateTime messageExpired) {
    if (room.signalDecodeError) {
      return const Text('Decode Error', style: TextStyle(color: Colors.pink));
    }
    if (room.lastMessageModel == null) {
      return const Text('');
    }
    Message m = room.lastMessageModel!;
    late String text;
    if (m.mediaType == MessageMediaType.text) {
      text = m.realMessage ?? m.content;
    } else {
      text = '${[m.mediaType.name]}';
    }
    if (m.isMeSend) {
      text = 'You: $text';
    }
    if (room.isMute && room.unReadCount > 1) {
      text = '[${room.unReadCount} messages] $text';
    }
    var style = TextStyle(
        color: Theme.of(Get.context!).colorScheme.onSurface.withOpacity(0.6));
    if (m.isMeSend) {
      if (m.sent == SendStatusType.failed ||
          (m.sent == SendStatusType.sending &&
              m.createdAt.isBefore(messageExpired))) {
        style = style.copyWith(color: Colors.red);
      }
    }

    return Text(text,
        maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
  }

  static Widget getRelaySubtitle(Message message) {
    if (message.mediaType == MessageMediaType.text) {
      return Text(
        message.realMessage ?? message.content,
        maxLines: 3,
        style: Theme.of(Get.context!).textTheme.bodyMedium,
      );
    }
    if (message.mediaType == MessageMediaType.image) {
      try {
        var mfi = MsgFileInfo.fromJson(jsonDecode(message.realMessage!));
        if (mfi.localPath != null) {
          return ImageMinPreviewWidget(mfi.localPath!);
        }
      } catch (e, s) {
        logger.e(e.toString(), stackTrace: s);
      }
    }

    return Text(
      message.mediaType.name,
      style: Theme.of(Get.context!).textTheme.bodyMedium,
    );
  }

  static Future showRoomActionSheet(BuildContext context, Room room,
      {Function? onDeleteHistory, Function? onDeletRoom}) async {
    showCupertinoModalPopup<void>(
      context: context,
      builder: (BuildContext context) => CupertinoActionSheet(
          title: Text(
            room.getRoomName(),
            style: const TextStyle(fontSize: 18),
          ),
          // message: const Text('Message'),
          actions: <CupertinoActionSheetAction>[
            CupertinoActionSheetAction(
              /// This parameter indicates the action would be a default
              /// default behavior, turns the action's text to bold text.
              onPressed: () async {
                await RoomService().deleteRoomMessage(room);
                await Get.find<HomeController>()
                    .loadIdentityRoomList(room.identityId);
                if (onDeleteHistory != null) {
                  onDeleteHistory();
                }
                Get.back();
              },
              child: const Text('Clear history'),
            ),
            if (room.type == RoomType.common)
              CupertinoActionSheetAction(
                isDestructiveAction: true,
                onPressed: () async {
                  try {
                    EasyLoading.show(status: 'Loading...');
                    await RoomService().deleteRoom(room);
                    if (onDeletRoom != null) {
                      onDeletRoom();
                    }
                    EasyLoading.showSuccess('Success');
                    await Get.find<HomeController>()
                        .loadIdentityRoomList(room.identityId);
                  } catch (e, s) {
                    EasyLoading.dismiss();
                    logger.e(e.toString(), error: e, stackTrace: s);
                    EasyLoading.showError(e.toString());
                  }
                  Get.back();
                },
                child: const Text('Delete chat'),
              ),
            CupertinoActionSheetAction(
              onPressed: () {
                Get.back();
              },
              child: const Text('Cancel'),
            )
          ]),
    );
  }

  static SettingsTile mediaSection(ChatController chatController) {
    return SettingsTile.navigation(
      leading: const Icon(
        CupertinoIcons.folder,
      ),
      title: const Text('Photos, Videos & Files'),
      onPressed: (context) async {
        Get.to(() => ChatMediaFilesPage(chatController.roomObs.value));
      },
    );
  }

  static SettingsTile messageLimitSection(ChatController chatController) {
    return SettingsTile.navigation(
      leading: const Icon(
        CupertinoIcons.folder,
      ),
      title: const Text('Message limit'),
      value: Text('${chatController.messageLimit.value}'),
    );
  }

  static SettingsTile clearHistory(ChatController chatController) {
    return SettingsTile(
      leading: const Icon(
        Icons.clear_all,
      ),
      title: const Text(
        'Clear History',
      ),
      onPressed: (context) {
        Get.dialog(CupertinoAlertDialog(
          title: const Text("Clean all messages?"),
          actions: <Widget>[
            CupertinoDialogAction(
              child: const Text(
                'Cancel',
              ),
              onPressed: () {
                Get.back();
              },
            ),
            CupertinoDialogAction(
                isDestructiveAction: true,
                child: const Text(
                  'Delete',
                ),
                onPressed: () async {
                  Get.back();
                  try {
                    EasyLoading.show(status: 'Processing');
                    await RoomService()
                        .deleteRoomMessage(chatController.roomObs.value);
                    chatController.messages.clear();
                    EasyLoading.showSuccess('Successfully');
                  } catch (e) {
                    EasyLoading.showError(e.toString());
                  }
                }),
          ],
        ));
      },
    );
  }

  static SettingsTile fromContactClick(String pubkey, int identityId,
      [String? greeting]) {
    return SettingsTile(
      title: FutureBuilder(
          future: RoomService().getRoomAndContainSession(pubkey, identityId),
          builder: (context, snapshot) {
            Room? room = snapshot.data;
            if (room == null) {
              return FilledButton(
                onPressed: () async {
                  Identity identity =
                      Get.find<HomeController>().identities[identityId]!;
                  await RoomService().createRoomAndsendInvite(pubkey,
                      identity: identity, greeting: greeting);
                },
                child: const Text('Add'),
              );
            }
            return FilledButton(
              onPressed: () async {
                await Get.offAndToNamed('/room/${room.id}', arguments: room);
                await Get.find<HomeController>()
                    .loadIdentityRoomList(room.identityId);
              },
              child: const Text('Send Message'),
            );
          }),
    );
  }

  static Future processUserQRCode(QRUserModel model) async {
    if (model.time <
        DateTime.now().millisecondsSinceEpoch -
            1000 * 3600 * KeychatGlobal.oneTimePubkeysLifetime) {
      EasyLoading.showToast('QRCode expired');
      return;
    }
    Identity identity = Get.find<HomeController>().getSelectedIdentity();

    String pubkey = rustNostr.getHexPubkeyByBech32(bech32: model.pubkey);
    String npub = rustNostr.getBech32PubkeyByHex(hex: model.pubkey);
    String globalSign = model.globalSign;
    String needVerifySignStr =
        "Keychat-${model.pubkey}-${model.curve25519PkHex}-${model.time}";
    bool sign = await rustNostr.verifySchnorr(
        pubkey: pubkey,
        sig: globalSign,
        content: needVerifySignStr,
        hash: true);
    if (!sign) {
      EasyLoading.showToast('QRCode globalSign error');
      return;
    }

    Contact contact =
        Contact(pubkey: pubkey, npubkey: npub, identityId: identity.id)
          ..hisRelay = model.relay.isEmpty ? null : model.relay
          ..curve25519PkHex = model.curve25519PkHex
          ..name = model.name;

    await Get.off(() => ContactPage(
          identityId: identity.id,
          contact: contact,
          title: 'Add Contact',
        )..model = model);
  }
}
