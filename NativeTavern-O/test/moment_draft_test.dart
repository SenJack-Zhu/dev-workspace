import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/moment_draft.dart';

void main() {
  test('compose messages ask the character to post as themselves', () {
    final messages = composeMomentMessages(
      characterName: 'Ava',
      characterCard: 'name: Ava\npersonality: dry',
      knowledge: 'Keeps a spare key under the pot.',
      conversations: 'User: Did you lock the gate?\nAva: Of course.',
      recentPosts: 'The garden is quiet tonight.',
    );

    expect(messages, hasLength(2));
    expect(messages.first['role'], 'system');
    expect(messages.first['content'], contains('Ava'));
    expect(messages.first['content'], contains('friends-circle'));
    expect(
        messages.first['content'], contains('choose naturally between like'));
    expect(messages.first['content'], contains('Comment only when'));
    expect(messages.first['content'], contains('Never publish a reaction'));
    expect(messages.last['content'], contains('spare key'));
    expect(messages.last['content'], contains('lock the gate'));
  });

  test('friend comment drafts only accept known posts', () {
    final draft = parseFriendCommentDraft(
      '{"post_id":"p1","body":"Nice gate."}',
      allowedPostIds: {'p1'},
    );
    expect(draft?.body, 'Nice gate.');
    expect(
      parseFriendCommentDraft(
        '{"post_id":"nope","body":"Nice gate."}',
        allowedPostIds: {'p1'},
      ),
      isNull,
    );
  });

  test('a reply with a post id is a comment, not a new post', () {
    final plan = parseMomentWakePlan(
      '{"action":"comment","post_id":"p1","body":"恭喜。"}',
      allowedPostIds: {'p1'},
    );
    expect(plan?.isComment, isTrue);
    expect(plan?.comment?.body, '恭喜。');
    expect(
      parseMomentWakePlan(
        '{"post_id":"p1","body":"Save me a cup."}',
        allowedPostIds: {'p1'},
      )?.isComment,
      isTrue,
    );
    expect(
      parseMomentWakePlan(
        '{"kind":"text","body":"Locked it."}',
        allowedPostIds: {'p1'},
      )?.draft?.body,
      'Locked it.',
    );
  });

  test('a post that answers the player is treated as a comment', () {
    final targets = [
      const MomentCommentTarget(
        id: 'player-1',
        body: '我的新女友，你们感受一下',
        fromPlayer: true,
      ),
    ];
    final plan = parseMomentWakePlan(
      '{"action":"post","kind":"text","body":"等等，第一天就直接官宣新女友？"}',
      allowedPostIds: {'player-1'},
      targets: targets,
    );
    expect(plan?.isComment, isTrue);
    expect(plan?.comment?.postId, 'player-1');
    expect(
      bestReplyPostId(
        '今晚练刀三百式，心很静。',
        targets: targets,
      ),
      isNull,
    );
  });

  test('parseMomentDraft accepts text, photo, and skip', () {
    expect(
      parseMomentDraft('{"kind":"text","body":"Locked it."}')!.body,
      'Locked it.',
    );
    expect(
      parseMomentDraft(
        '{"kind":"text_image","body":"Look.","image_prompt":"a rusted gate"}',
      )!
          .wantsPhoto,
      isTrue,
    );
    expect(parseMomentDraft('{"skip":true}'), isNull);
    expect(parseMomentDraft('{"kind":"text","body":""}'), isNull);
  });
}
