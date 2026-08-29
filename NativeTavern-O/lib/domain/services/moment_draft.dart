import 'dart:convert';

enum MomentDraftKind { text, image, textImage }

enum MomentAgentAction {
  skip,
  post,
  comment,
  reply,
  like,
  unlike,
  deleteOwnComment,
  messagePlayer,
}

final class MomentAgentDecision {
  const MomentAgentDecision(
      {required this.action,
      this.postId,
      this.commentId,
      this.parentCommentId,
      this.body,
      this.imagePrompt});
  final MomentAgentAction action;
  final String? postId;
  final String? commentId;
  final String? parentCommentId;
  final String? body;
  final String? imagePrompt;
}

MomentAgentDecision? parseMomentAgentDecision(
  String response, {
  required Set<String> allowedPostIds,
  Set<String> allowedCommentIds = const {},
  Set<String> allowedParentCommentIds = const {},
}) {
  final value = jsonDecode(_jsonObjectFromResponse(response));
  if (value is! Map<String, dynamic>) return null;
  if (!value.containsKey('action')) return null;
  final actionName = '${value['action'] ?? 'skip'}'.trim();
  final action = switch (actionName) {
    'post' => MomentAgentAction.post,
    'comment' => MomentAgentAction.comment,
    'reply' => MomentAgentAction.reply,
    'like' => MomentAgentAction.like,
    'unlike' => MomentAgentAction.unlike,
    'delete_comment' ||
    'deleteOwnComment' =>
      MomentAgentAction.deleteOwnComment,
    'message_player' || 'messagePlayer' => MomentAgentAction.messagePlayer,
    _ => MomentAgentAction.skip,
  };
  final postId =
      value['post_id'] is String ? (value['post_id'] as String).trim() : null;
  final commentId = value['comment_id'] is String
      ? (value['comment_id'] as String).trim()
      : null;
  final parentId = value['parent_comment_id'] is String
      ? (value['parent_comment_id'] as String).trim()
      : null;
  final body = value['body'] is String
      ? _clip((value['body'] as String).trim(), 500)
      : null;
  if (action == MomentAgentAction.comment ||
      action == MomentAgentAction.like ||
      action == MomentAgentAction.unlike) {
    if (postId == null || !allowedPostIds.contains(postId)) return null;
  }
  if (action == MomentAgentAction.comment && (body == null || body.isEmpty)) {
    return null;
  }
  if (action == MomentAgentAction.reply &&
      (postId == null ||
          !allowedPostIds.contains(postId) ||
          parentId == null ||
          !allowedParentCommentIds.contains(parentId) ||
          body == null ||
          body.isEmpty)) return null;
  if (action == MomentAgentAction.deleteOwnComment &&
      (commentId == null || !allowedCommentIds.contains(commentId)))
    return null;
  if (action == MomentAgentAction.messagePlayer &&
      (body == null || body.isEmpty)) return null;
  return MomentAgentDecision(
    action: action,
    postId: postId,
    commentId: commentId,
    parentCommentId: parentId,
    body: body,
    imagePrompt: value['image_prompt'] is String
        ? _clip((value['image_prompt'] as String).trim(), 800)
        : null,
  );
}

/// What a character decided to post on the moments feed.
final class MomentDraft {
  const MomentDraft({
    required this.kind,
    this.body = '',
    this.imagePrompt,
  });

  final MomentDraftKind kind;
  final String body;
  final String? imagePrompt;

  bool get wantsPhoto =>
      kind == MomentDraftKind.image || kind == MomentDraftKind.textImage;

  bool get hasBody => body.trim().isNotEmpty;
}

List<Map<String, dynamic>> composeMomentMessages({
  required String characterName,
  required String characterCard,
  required String knowledge,
  required String conversations,
  required String recentPosts,
  String friends = '',
  String visibleMoments = '',
  String commentTargets = '',
  bool mayPost = true,
}) {
  final postRule = mayPost
      ? '''
- action=post: something from YOUR life. Never reply to, quote, congratulate, or address someone else's moment as your own post.
- kind=text: body required, 1-4 short sentences in your voice.
- kind=image: image_prompt required; body may be empty.
- kind=text_image: body and image_prompt required.
- image_prompt describes the photo you would post. It is not shown to others.'''
      : '''
- You already posted recently. Do not create another post.
- If you want to react, choose like, comment/reply, or skip based on what feels natural.''';
  return [
    {
      'role': 'system',
      'content': '''
You are $characterName on a friends-circle moments feed.
Speak as yourself. Do not summarize a chapter. Do not write a recap.
You only see your own posts, posts by your friends, posts by the player, and comments on those posts.
You cannot see strangers' moments.

Do exactly one thing. You are an autonomous agent, so skip when there is no
natural reason to act:
- comment/reply: write under a visible post or comment.
- like: like a visible post.
- post: a new moment about your own life.
- message_player: send a private message in an existing chat when a moment
  gives you a genuinely urgent reason.
- skip: do nothing.

When reacting to the player or a friend, choose naturally between like,
comment/reply, and skip. Comment only when you have something specific to say.
Never publish a reaction as your own post.

Return JSON only:
{"action":"comment","post_id":"...","body":"..."}
{"action":"reply","post_id":"...","parent_comment_id":"...","body":"..."}
{"action":"like","post_id":"..."}
{"action":"message_player","body":"..."}
{"action":"post","kind":"text"|"image"|"text_image","body":"...","image_prompt":"..."}
{"action":"skip"}

Rules:
- action=comment: post_id must be one of comment_targets. One short comment only.
$postRule
- If nothing feels natural, return {"action":"skip"}.
''',
    },
    {
      'role': 'user',
      'content': jsonEncode({
        'character': characterCard,
        'knowledge': knowledge,
        'conversations': conversations,
        'friends': friends,
        'visible_moments': visibleMoments,
        'comment_targets': commentTargets,
        'recent_posts': recentPosts,
        'may_post': mayPost,
      }),
    },
  ];
}

List<Map<String, dynamic>> composeFriendCommentMessages({
  required String characterName,
  required String visiblePosts,
}) {
  return [
    {
      'role': 'system',
      'content': '''
You are $characterName commenting on a moments post you can see.
That is a friend's post or the player's post, plus comments already on it.
Speak as yourself. One short comment only. You cannot mention posts you cannot see.

Return JSON only:
{"skip": false, "post_id": "...", "body": "..."}
or {"skip": true}
''',
    },
    {
      'role': 'user',
      'content': jsonEncode({'visible_posts': visiblePosts}),
    },
  ];
}

final class MomentFriendCommentDraft {
  const MomentFriendCommentDraft({required this.postId, required this.body});

  final String postId;
  final String body;
}

final class MomentCommentTarget {
  const MomentCommentTarget({
    required this.id,
    required this.body,
    this.fromPlayer = false,
  });

  final String id;
  final String body;
  final bool fromPlayer;
}

/// If [body] is reacting to someone else's moment, the post it belongs under.
String? bestReplyPostId(
  String body, {
  required Iterable<MomentCommentTarget> targets,
}) {
  final reply = body.trim();
  if (reply.isEmpty || targets.isEmpty) return null;
  final lowered = reply.toLowerCase();
  final reacting = _looksLikeReply(lowered);
  String? bestId;
  var bestScore = 0;
  for (final target in targets) {
    var score = 0;
    for (final phrase in _distinctivePhrases(target.body)) {
      if (lowered.contains(phrase.toLowerCase())) {
        score += phrase.length >= 4 ? 4 : 3;
      }
    }
    if (target.fromPlayer && reacting) score += 2;
    if (score > bestScore) {
      bestScore = score;
      bestId = target.id;
    }
  }
  return bestScore >= 3 ? bestId : null;
}

bool _looksLikeReply(String lowered) {
  const markers = [
    '恭喜',
    '祝福',
    '脱单',
    '官宣',
    '新女友',
    '女朋友',
    '你们',
    '你这',
    '你的',
    '祝顺利',
    '祝贺',
    '第一天',
    'congrats',
    'congratulations',
  ];
  return markers.any(lowered.contains);
}

Iterable<String> _distinctivePhrases(String body) sync* {
  final matches =
      RegExp(r'[\u4e00-\u9fff]{2,}|[a-zA-Z0-9]{3,}').allMatches(body);
  for (final match in matches) {
    final token = match.group(0)!;
    yield token;
    if (token.length >= 4) {
      yield token.substring(token.length - 2);
      yield token.substring(token.length - 3);
    }
  }
}

MomentFriendCommentDraft? parseFriendCommentDraft(
  String response, {
  required Set<String> allowedPostIds,
}) {
  final document = jsonDecode(_jsonObjectFromResponse(response));
  if (document is! Map<String, dynamic>) return null;
  if (document['skip'] == true) return null;
  final postId = document['post_id'] is String
      ? (document['post_id'] as String).trim()
      : document['postId'] is String
          ? (document['postId'] as String).trim()
          : '';
  final body =
      document['body'] is String ? (document['body'] as String).trim() : '';
  if (postId.isEmpty || body.isEmpty || !allowedPostIds.contains(postId)) {
    return null;
  }
  return MomentFriendCommentDraft(postId: postId, body: _clip(body, 200));
}

/// One wake decision: a new post, a comment on someone else's post, or skip.
final class MomentWakePlan {
  const MomentWakePlan.post(this.draft) : comment = null;
  const MomentWakePlan.comment(this.comment) : draft = null;

  final MomentDraft? draft;
  final MomentFriendCommentDraft? comment;

  bool get isComment => comment != null;
}

MomentWakePlan? parseMomentWakePlan(
  String response, {
  required Set<String> allowedPostIds,
  Iterable<MomentCommentTarget> targets = const [],
  bool mayPost = true,
}) {
  final document = jsonDecode(_jsonObjectFromResponse(response));
  if (document is! Map<String, dynamic>) return null;
  if (document['skip'] == true || document['action'] == 'skip') {
    return null;
  }
  final action =
      document['action'] is String ? (document['action'] as String).trim() : '';
  final hasPostId = (document['post_id'] is String &&
          (document['post_id'] as String).trim().isNotEmpty) ||
      (document['postId'] is String &&
          (document['postId'] as String).trim().isNotEmpty);
  if (action == 'comment' || (hasPostId && action != 'post')) {
    final comment = parseFriendCommentDraft(
      response,
      allowedPostIds: allowedPostIds,
    );
    return comment == null ? null : MomentWakePlan.comment(comment);
  }
  final draft = parseMomentDraft(response);
  if (draft != null && draft.hasBody) {
    final replyId = bestReplyPostId(draft.body, targets: targets);
    if (replyId != null) {
      return MomentWakePlan.comment(
        MomentFriendCommentDraft(postId: replyId, body: _clip(draft.body, 200)),
      );
    }
  }
  if (!mayPost) return null;
  return draft == null ? null : MomentWakePlan.post(draft);
}

MomentDraft? parseMomentDraft(String response) {
  final document = jsonDecode(_jsonObjectFromResponse(response));
  if (document is! Map<String, dynamic>) return null;
  if (document['skip'] == true) return null;

  final kind = _kind(document['kind']);
  if (kind == null) return null;
  final body =
      document['body'] is String ? (document['body'] as String).trim() : '';
  final imagePrompt = document['image_prompt'] is String
      ? (document['image_prompt'] as String).trim()
      : document['imagePrompt'] is String
          ? (document['imagePrompt'] as String).trim()
          : '';
  final effectivePrompt = imagePrompt.isEmpty ? null : imagePrompt;

  switch (kind) {
    case MomentDraftKind.text:
      if (body.isEmpty) return null;
      return MomentDraft(kind: kind, body: _clip(body, 500));
    case MomentDraftKind.image:
      if (effectivePrompt == null) return null;
      return MomentDraft(
        kind: kind,
        body: _clip(body, 500),
        imagePrompt: _clip(effectivePrompt, 800),
      );
    case MomentDraftKind.textImage:
      if (body.isEmpty || effectivePrompt == null) return null;
      return MomentDraft(
        kind: kind,
        body: _clip(body, 500),
        imagePrompt: _clip(effectivePrompt, 800),
      );
  }
}

MomentDraftKind? _kind(Object? value) {
  if (value is! String) return null;
  switch (value.trim()) {
    case 'text':
      return MomentDraftKind.text;
    case 'image':
      return MomentDraftKind.image;
    case 'text_image':
    case 'textImage':
    case 'photo':
      return MomentDraftKind.textImage;
    default:
      return null;
  }
}

String _jsonObjectFromResponse(String response) {
  final trimmed = response.trim();
  final start = trimmed.indexOf('{');
  final end = trimmed.lastIndexOf('}');
  if (start < 0 || end < start) {
    throw const FormatException('Response does not contain JSON.');
  }
  return trimmed.substring(start, end + 1);
}

String _clip(String value, int max) {
  if (value.length <= max) return value;
  return value.substring(0, max).trim();
}
