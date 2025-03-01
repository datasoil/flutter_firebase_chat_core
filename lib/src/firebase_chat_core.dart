import 'dart:developer';
import 'dart:io';

import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'util.dart';

/// Provides access to Firebase chat data. Singleton, use
/// FirebaseChatCore.instance to aceess methods.
class FirebaseChatCore {
  FirebaseChatCore._privateConstructor() {
    FirebaseAuth.instance.authStateChanges().listen((User? user) {
      firebaseUser = user;
    });
  }

  /// Current logged in user in Firebase. Does not update automatically.
  /// Use [FirebaseAuth.authStateChanges] to listen to the state changes.
  User? firebaseUser = FirebaseAuth.instance.currentUser;

  /// Singleton instance
  static final FirebaseChatCore instance =
      FirebaseChatCore._privateConstructor();

  /// Creates a chat group room with [users]. Creator is automatically
  /// added to the group. [name] is required and will be used as
  /// a group name. Add an optional [imageUrl] that will be a group avatar
  /// and [metadata] for any additional custom data.
  Future<types.Room> createGroupRoom({
    String? imageUrl,
    Map<String, dynamic>? metadata,
    required String name,
    required List<types.User> users,
  }) async {
    if (firebaseUser == null) return Future.error('User does not exist');

    final currentUser = await fetchUser(firebaseUser!.uid);
    final roomUsers = [currentUser] + users;

    final room = await FirebaseFirestore.instance.collection('rooms').add({
      'createdAt': DateTime.now().toIso8601String(),
      'imageUrl': imageUrl,
      'metadata': metadata,
      'name': name,
      'type': types.RoomType.group.toShortString(),
      'updatedAt': DateTime.now().toIso8601String(),
      'userIds': roomUsers.map((u) => u.id).toList(),
      'userRoles': roomUsers.fold<Map<String, String?>>(
        {},
        (previousValue, element) => {
          ...previousValue,
          element.id: element.role?.toShortString(),
        },
      ),
    });

    return types.Room(
      id: room.id,
      imageUrl: imageUrl,
      metadata: metadata,
      name: name,
      type: types.RoomType.group,
      users: roomUsers,
    );
  }

  /// Creates a direct chat for 2 people. Add [metadata] for any additional
  /// custom data.
  Future<types.Room> createRoom(
    types.User otherUser, {
    Map<String, dynamic>? metadata,
  }) async {
    if (firebaseUser == null) return Future.error('User does not exist');

    final query = await FirebaseFirestore.instance
        .collection('rooms')
        .where('userIds', arrayContains: firebaseUser!.uid)
        .get();

    final rooms = await processRoomsQuery(firebaseUser!, query);

    try {
      return rooms.firstWhere((room) {
        if (room.type == types.RoomType.group) return false;

        final userIds = room.users.map((u) => u.id);
        return userIds.contains(firebaseUser!.uid) &&
            userIds.contains(otherUser.id);
      });
    } catch (e) {
      // Do nothing if room does not exist
      // Create a new room instead
    }

    final currentUser = await fetchUser(firebaseUser!.uid);
    final users = [currentUser, otherUser];

    final room = await FirebaseFirestore.instance.collection('rooms').add({
      'createdAt': DateTime.now().toIso8601String(),
      'imageUrl': null,
      'metadata': metadata,
      'name': null,
      'type': types.RoomType.direct.toShortString(),
      'updatedAt': DateTime.now().toIso8601String(),
      'userIds': users.map((u) => u.id).toList(),
      'userRoles': null,
    });

    return types.Room(
      id: room.id,
      metadata: metadata,
      type: types.RoomType.direct,
      users: users,
    );
  }

  Future<types.Room> createRoomWithCustomId(
      {String? imageUrl,
      Map<String, dynamic>? metadata,
      required String name,
      required List<types.User> users,
      required String uuid}) async {
    if (firebaseUser == null) return Future.error('User does not exist');

    final currentUser = await fetchUser(firebaseUser!.uid);
    final roomUsers = [currentUser] + users;
    const bot = types.User(id: 'bot', firstName: 'Coach Bot');
    final room =
        await FirebaseFirestore.instance.collection('rooms').doc(uuid).set({
      'createdAt': DateTime.now(),
      'imageUrl': imageUrl,
      'metadata': metadata,
      'name': name,
      'type': types.RoomType.group.toShortString(),
      'updatedAt': DateTime.now(),
      'userIds': roomUsers.map((u) => u.id).toList(),
      'clientId': currentUser.id,
      'userRoles': roomUsers.fold<Map<String, String?>>(
        {},
        (previousValue, element) => {
          ...previousValue,
          element.id: element.role?.toShortString(),
        },
      ),
    });
    return types.Room(
      id: uuid,
      imageUrl: imageUrl,
      metadata: metadata,
      name: name,
      type: types.RoomType.group,
      users: roomUsers + [bot],
    );
  }

  /// Creates [types.User] in Firebase to store name and avatar used on
  /// rooms list
  Future<void> createUserInFirestore(types.User user) async {
    await FirebaseFirestore.instance.collection('users').doc(user.id).set({
      'createdAt': DateTime.now().toIso8601String(),
      'firstName': user.firstName,
      'imageUrl': user.imageUrl,
      'lastName': user.lastName,
      'lastSeen': user.lastSeen,
      'metadata': user.metadata,
      'role': user.role?.toShortString(),
      'updatedAt': DateTime.now().toIso8601String(),
    });
  }

  /// Removes [types.User] from `users` collection in Firebase
  Future<void> deleteUserFromFirestore(String userId) async {
    await FirebaseFirestore.instance.collection('users').doc(userId).delete();
  }

  List<types.Message> orderList(List<types.Message> l) {
    l.sort((a, b) => a.createdAt!.compareTo(b.createdAt!));
    return l;
  }

  Stream<Map<String, dynamic>> lastMessage(types.Room room) {
    return FirebaseFirestore.instance
        .collection('rooms/${room.id}/messages')
        .where('visibility',
            arrayContains: FirebaseAuth.instance.currentUser!.uid)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((event) {
      final data = event.docs.first.data();
      data['createdAt'] = data['createdAt']?.millisecondsSinceEpoch;
      data['updatedAt'] = data['updatedAt']?.millisecondsSinceEpoch;
      return data;
    });
  }

  /// Returns a stream of messages from Firebase for a given room
  Stream<List<types.Message>> messages(types.Room room) {
    return FirebaseFirestore.instance
        .collection('rooms/${room.id}/messages')
        .where('visibility',
            arrayContains: FirebaseAuth.instance.currentUser!.uid)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map(
      (snapshot) {
        return snapshot.docs.fold<List<types.Message>>(
          [],
          (previousValue, element) {
            final data = element.data();
            final author = room.users.firstWhere(
              (u) => u.id == data['authorId'],
              orElse: () => types.User(id: data['authorId'] as String),
            );

            data['author'] = author.toJson();
            data['id'] = element.id;
            if (data['createdAt'] is Timestamp) {
              data['createdAt'] = data['createdAt']?.millisecondsSinceEpoch;
            }
            if (data['updatedAt'] is Timestamp) {
              data['updatedAt'] = data['updatedAt']?.millisecondsSinceEpoch;
            }
            /*try {
              data['createdAt'] = DateTime.now().toIso8601String();
              data['updatedAt'] = DateTime.now().toIso8601String();
            } catch (e) {
              // Ignore errors, null values are ok
            }*/
            data.removeWhere((key, value) => key == 'authorId');
            previousValue.add(types.Message.fromJson(data));
            var n = orderList(previousValue);
            n = List.from(n.reversed);
            return n;
          },
        );
      },
    );
  }

  Stream<bool> hasUnseenMessages(types.Room room) {
    return FirebaseFirestore.instance
        .collection('rooms/${room.id}/messages')
        .where('visibility',
            arrayContains: FirebaseAuth.instance.currentUser!.uid)
        .where('status', isEqualTo: 'delivered')
        .where('authorId', isNotEqualTo: FirebaseAuth.instance.currentUser!.uid)
        //.orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.isNotEmpty;
    });
  }

  /// Returns a stream of unseen messages from Firebase for a given room
  Stream<List<types.Message>> unseenMessages(types.Room room) {
    return FirebaseFirestore.instance
        .collection('rooms/${room.id}/messages')
        //.orderBy('createdAt', descending: true)
        .where('visibility',
            arrayContains: FirebaseAuth.instance.currentUser!.uid)
        .where('status', isEqualTo: 'delivered')
        .where('authorId', isNotEqualTo: FirebaseAuth.instance.currentUser!.uid)
        .snapshots()
        .map(
      (snapshot) {
        return snapshot.docs.fold<List<types.Message>>(
          [],
          (previousValue, element) {
            final data = element.data();
            final author = room.users.firstWhere(
              (u) => u.id == data['authorId'],
              orElse: () => types.User(id: data['authorId'] as String),
            );

            data['author'] = author.toJson();
            data['id'] = element.id;
            if (data['createdAt'] is Timestamp) {
              data['createdAt'] = data['createdAt']?.millisecondsSinceEpoch;
            }
            if (data['updatedAt'] is Timestamp) {
              data['updatedAt'] = data['updatedAt']?.millisecondsSinceEpoch;
            }
            /*try {
              data['createdAt'] = DateTime.now().toIso8601String();
              data['updatedAt'] = DateTime.now().toIso8601String();
            } catch (e) {
              // Ignore errors, null values are ok
            }*/
            data.removeWhere((key, value) => key == 'authorId');
            previousValue.add(types.Message.fromJson(data));
            var n = orderList(previousValue);
            n = List.from(n.reversed);
            return n;
          },
        );
      },
    );
  }

  Future<void> setMessageSeen(types.Message message, String roomId) async {
    if (firebaseUser == null) return;
    //if (message.author.id != firebaseUser!.uid) return;

    final updMessage = {
      'updatedAt': FieldValue.serverTimestamp(),
      'status': 'seen',
    };

    await FirebaseFirestore.instance
        .collection('rooms/$roomId/messages')
        .doc(message.id)
        .update(updMessage);
  }

  /// Returns a stream of changes in a room from Firebase
  Stream<types.Room> room(String roomId) {
    if (firebaseUser == null) return const Stream.empty();

    return FirebaseFirestore.instance
        .collection('rooms')
        .doc(roomId)
        .snapshots()
        .asyncMap((doc) => processRoomDocument(doc, firebaseUser!));
  }

  /// Returns a stream of rooms from Firebase. Only rooms where current
  /// logged in user exist are returned. [orderByUpdatedAt] is used in case
  /// you want to have last modified rooms on top, there are a couple
  /// of things you will need to do though:
  /// 1) Make sure `updatedAt` exists on all rooms
  /// 2) Write a Cloud Function which will update `updatedAt` of the room
  /// when the room changes or new messages come in
  /// 3) Create an Index (Firestore Database -> Indexes tab) where collection ID
  /// is `rooms`, field indexed are `userIds` (type Arrays) and `updatedAt`
  /// (type Descending), query scope is `Collection`
  Stream<List<types.Room>> rooms({bool orderByUpdatedAt = false}) {
    if (firebaseUser == null) return const Stream.empty();

    final collection = orderByUpdatedAt
        ? FirebaseFirestore.instance
            .collection('rooms')
            .where('userIds', arrayContains: firebaseUser!.uid)
            .orderBy('updatedAt', descending: true)
        : FirebaseFirestore.instance
            .collection('rooms')
            .where('userIds', arrayContains: firebaseUser!.uid);

    return collection
        .snapshots()
        .asyncMap((query) => processRoomsQuery(firebaseUser!, query));
  }

  void changeRoomStatus(String roomId, String status) async {
    return await FirebaseFirestore.instance
        .collection('rooms')
        .doc(roomId)
        .update({
      'metadata': {'status': status}
    });
  }

  Future<void> sendMediaMessage(
      dynamic partialMessage, String roomId, File file, String fileName,
      {Uint8List? thumbFile, String? thumbFileName, String? customPath}) async {
    if (firebaseUser == null) return;

    types.Message? message;
    if (partialMessage is types.PartialImage) {
      message = types.ImageMessage.fromPartial(
          author: types.User(id: firebaseUser!.uid),
          id: '',
          partialImage: partialMessage,
          roomId: roomId);
    } else if (partialMessage is types.PartialVideo) {
      message = types.VideoMessage.fromPartial(
          author: types.User(id: firebaseUser!.uid),
          id: '',
          partialVideo: partialMessage,
          roomId: roomId);
    }
    if (message != null) {
      final messageMap = message.toJson();
      messageMap.removeWhere((key, value) => key == 'author' || key == 'id');
      messageMap['authorId'] = firebaseUser!.uid;
      messageMap['createdAt'] = FieldValue.serverTimestamp();
      messageMap['updatedAt'] = FieldValue.serverTimestamp();
      messageMap['status'] = 'sent';

      dynamic messageRef;
      try {
        messageRef = await FirebaseFirestore.instance
            .collection('rooms/$roomId/messages')
            .add(messageMap);

        //se video carico la thumb
        if (message is types.VideoMessage) {
          if (thumbFile != null && thumbFileName != null) {
            //carico il file
            final messageId = messageRef.id as String?;
            final path = customPath != null
                ? customPath + '/' + (messageId ?? '') + '_th_' + thumbFileName
                : firebaseUser!.uid.toString() +
                    '/' +
                    roomId +
                    '/' +
                    thumbFileName;
            try {
              await FirebaseStorage.instance.ref(path).putData(thumbFile);
              final url =
                  await FirebaseStorage.instance.ref(path).getDownloadURL();
              messageMap['thumbUri'] = url;
            } catch (err) {
              debugPrint(err.toString());
              throw 'Error uploading';
            }
          } else {
            throw 'Missing thumb data';
          }
        }
        //carico il file
        final messageId = messageRef.id as String?;
        final path = customPath != null
            ? customPath + '/' + (messageId ?? '') + '_' + fileName
            : firebaseUser!.uid.toString() + '/' + roomId + '/' + fileName;
        await FirebaseStorage.instance.ref(path).putFile(file);
        final url = await FirebaseStorage.instance.ref(path).getDownloadURL();
        //aggiorno il messaggio
        messageMap
            .removeWhere((key, value) => key == 'id' || key == 'createdAt');
        messageMap['updatedAt'] = FieldValue.serverTimestamp();
        messageMap['uri'] = url; //link immagine

        await FirebaseFirestore.instance
            .collection('rooms/$roomId/messages')
            .doc(messageRef.id as String?)
            .update(messageMap);
      } catch (e) {
        if (messageRef != null) {
          await FirebaseFirestore.instance
              .collection('rooms/$roomId/messages')
              .doc(messageRef.id as String?)
              .delete();
        }
        throw 'Invio media fallito';
      }
    }
  }

  /// Sends a message to the Firestore. Accepts any partial message and a
  /// room ID. If arbitraty data is provided in the [partialMessage]
  /// does nothing.
  void sendMessage(dynamic partialMessage, String roomId) async {
    if (firebaseUser == null) return;

    types.Message? message;
    if (partialMessage is types.PartialFile) {
      message = types.FileMessage.fromPartial(
          author: types.User(id: firebaseUser!.uid),
          id: '',
          partialFile: partialMessage,
          roomId: roomId);
    } else if (partialMessage is types.PartialImage) {
      message = types.ImageMessage.fromPartial(
          author: types.User(id: firebaseUser!.uid),
          id: '',
          partialImage: partialMessage,
          roomId: roomId);
    } else if (partialMessage is types.PartialText) {
      message = types.TextMessage.fromPartial(
          author: types.User(id: firebaseUser!.uid),
          id: '',
          partialText: partialMessage,
          roomId: roomId);
    } else if (partialMessage is types.PartialVideo) {
      message = types.VideoMessage.fromPartial(
          author: types.User(id: firebaseUser!.uid),
          id: '',
          partialVideo: partialMessage,
          roomId: roomId);
    } else if (partialMessage is types.PartialChoice) {
      message = types.ChoiceMessage.fromPartial(
          author: types.User(id: firebaseUser!.uid),
          id: '',
          partialChoice: partialMessage,
          roomId: roomId);
    } else if (partialMessage is types.PartialQuestion) {
      message = types.QuestionMessage.fromPartial(
          author: types.User(id: firebaseUser!.uid),
          id: '',
          partialQuestion: partialMessage,
          roomId: roomId);
    } else if (partialMessage is types.StartMessage) {
      message = types.StartMessage.fromPartial(
          author: types.User(id: firebaseUser!.uid),
          id: '',
          roomId: roomId,
          text: 'Start Bot!');
    } else if (partialMessage is types.CancelMessage) {
      message = types.CancelMessage.fromPartial(
          author: types.User(id: firebaseUser!.uid),
          id: '',
          roomId: roomId,
          text: 'Cancel');
    } else if (partialMessage is types.FulFilmentCoach) {
      message = types.FulFilmentCoach.fromPartial(
          author: types.User(id: firebaseUser!.uid),
          id: '',
          roomId: roomId,
          text: 'Conversazione terminata!');
    }
    if (message != null) {
      final messageMap = message.toJson();
      messageMap.removeWhere((key, value) => key == 'author' || key == 'id');
      messageMap['authorId'] = firebaseUser!.uid;
      messageMap['createdAt'] = FieldValue.serverTimestamp();
      messageMap['updatedAt'] = FieldValue.serverTimestamp();
      messageMap['roomId'] = roomId;
      messageMap['status'] = 'sent';
      await FirebaseFirestore.instance
          .collection('rooms/$roomId/messages')
          .add(messageMap);
    }
  }

  /// Updates a message in the Firestore. Accepts any message and a
  /// room ID. Message will probably be taken from the [messages] stream.
  void updateMessage(types.Message message, String roomId) async {
    if (firebaseUser == null) return;
    //if (message.author.id != firebaseUser!.uid) return;

    final messageMap = message.toJson();
    messageMap.removeWhere(
        (key, value) => key == 'id' || key == 'createdAt' || key == 'author');
    messageMap['updatedAt'] = FieldValue.serverTimestamp();

    await FirebaseFirestore.instance
        .collection('rooms/$roomId/messages')
        .doc(message.id)
        .update(messageMap);
  }

  /// Returns a stream of all users from Firebase
  Stream<List<types.User>> users() {
    if (firebaseUser == null) return const Stream.empty();
    return FirebaseFirestore.instance.collection('users').snapshots().map(
          (snapshot) => snapshot.docs.fold<List<types.User>>(
            [],
            (previousValue, element) {
              if (firebaseUser!.uid == element.id) return previousValue;

              return [...previousValue, processUserDocument(element)];
            },
          ),
        );
  }
}
