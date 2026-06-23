import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:holdclose/models/forum.dart';
import 'package:holdclose/services/forum_api_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String fakeJwt = 'header.payload.signature';

  /// Records every token request so tests can assert "the API client
  /// pulled exactly one JWT per call".
  Future<String> Function() recordingTokenLoader(List<int> counter,
      {String token = fakeJwt}) {
    return () async {
      counter.add(1);
      return token;
    };
  }

  ForumApiClient buildClient(_RecordingAdapter adapter,
      {String? baseUrl, ForumTokenLoader? tokenLoader}) {
    final Dio dio = Dio()..httpClientAdapter = adapter;
    return ForumApiClient(
      tokenLoader: tokenLoader ?? (() async => fakeJwt),
      dio: dio,
      baseUrl: baseUrl ?? 'https://forum-api.workers.dev',
    );
  }

  group('ForumApiClient — base URL handling', () {
    test('strips a trailing slash so concatenated paths stay single-slashed',
        () {
      final ForumApiClient client = ForumApiClient(
        tokenLoader: () async => fakeJwt,
        dio: Dio(),
        baseUrl: 'https://example.test/',
      );
      expect(client.baseUrl, 'https://example.test');
    });
  });

  // ---- Expired-session recovery (server-minted token, 2026-06-11) ---------

  group('expired-token recovery — 401 + Token-Expired retries ONCE', () {
    Map<String, Object?> profileJson() => <String, Object?>{
          'id': 'profile-1',
          'careblazers_user_id': 'user-1',
          'display_name': 'Caregiver_abc123',
          'avatar_url': null,
          'joined_at': '2026-05-30T12:00:00.000Z',
          'role': 'user',
        };

    test('recovers, retries with the refreshed token, and succeeds',
        () async {
      final _SequenceAdapter adapter = _SequenceAdapter(<_CannedResponse>[
        _CannedResponse.json(
          <String, Object?>{'error': 'token_expired'},
          statusCode: 401,
          extraHeaders: <String, List<String>>{
            'Token-Expired': <String>['true'],
          },
        ),
        _CannedResponse.json(profileJson()),
      ]);
      final List<String> servedTokens = <String>['stale-token', 'fresh-token'];
      int tokenCalls = 0;
      int recoveries = 0;
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final ForumApiClient client = ForumApiClient(
        tokenLoader: () async => servedTokens[tokenCalls++],
        onTokenExpired: () async {
          recoveries += 1;
          return true;
        },
        dio: dio,
        baseUrl: 'https://forum-api.workers.dev',
      );

      final ForumProfile profile = await client.bootstrapProfile();

      expect(profile.id, 'profile-1');
      expect(recoveries, 1);
      expect(adapter.requests, hasLength(2));
      expect(
        adapter.requests.first.headers['Authorization'],
        'Bearer stale-token',
      );
      expect(
        adapter.requests.last.headers['Authorization'],
        'Bearer fresh-token',
      );
    });

    test('failed recovery rethrows the original token-expired error '
        'without retrying', () async {
      final _SequenceAdapter adapter = _SequenceAdapter(<_CannedResponse>[
        _CannedResponse.json(
          <String, Object?>{'error': 'token_expired'},
          statusCode: 401,
          extraHeaders: <String, List<String>>{
            'Token-Expired': <String>['true'],
          },
        ),
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final ForumApiClient client = ForumApiClient(
        tokenLoader: () async => 'stale-token',
        onTokenExpired: () async => false,
        dio: dio,
        baseUrl: 'https://forum-api.workers.dev',
      );

      await expectLater(
        client.bootstrapProfile(),
        throwsA(isA<ForumApiException>()
            .having((ForumApiException e) => e.tokenExpired, 'tokenExpired',
                isTrue)),
      );
      expect(adapter.requests, hasLength(1));
    });

    test('a second consecutive Token-Expired does NOT loop — exactly one '
        'retry, then the error surfaces', () async {
      _CannedResponse expired() => _CannedResponse.json(
            <String, Object?>{'error': 'token_expired'},
            statusCode: 401,
            extraHeaders: <String, List<String>>{
              'Token-Expired': <String>['true'],
            },
          );
      final _SequenceAdapter adapter =
          _SequenceAdapter(<_CannedResponse>[expired(), expired()]);
      int recoveries = 0;
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final ForumApiClient client = ForumApiClient(
        tokenLoader: () async => 'always-stale',
        onTokenExpired: () async {
          recoveries += 1;
          return true;
        },
        dio: dio,
        baseUrl: 'https://forum-api.workers.dev',
      );

      await expectLater(
        client.bootstrapProfile(),
        throwsA(isA<ForumApiException>()
            .having((ForumApiException e) => e.tokenExpired, 'tokenExpired',
                isTrue)),
      );
      expect(recoveries, 1);
      expect(adapter.requests, hasLength(2));
    });
  });

  group('GoogleAuthResult — server-minted session token parsing', () {
    test('parses token + token_expires_at from the auth/google body', () {
      final GoogleAuthResult result =
          GoogleAuthResult.fromJson(<String, Object?>{
        'user_id': 'user-1',
        'email': 'c@example.com',
        'name': 'Caregiver',
        'username': null,
        'token': 'minted.by.server',
        'token_expires_at': 1783794304,
      });
      expect(result.token, 'minted.by.server');
      expect(result.tokenExpiresAt, 1783794304);
    });

    test('tolerates an older backend that omits the token fields', () {
      final GoogleAuthResult result =
          GoogleAuthResult.fromJson(<String, Object?>{
        'user_id': 'user-1',
        'email': 'c@example.com',
        'name': 'Caregiver',
      });
      expect(result.token, isNull);
      expect(result.tokenExpiresAt, isNull);
    });
  });

  // ---- Auth header presence ------------------------------------------------

  group('Authorization header — Phase 13.9 contract', () {
    test('protected POST attaches Bearer <token>', () async {
      final _RecordingAdapter adapter =
          _RecordingAdapter.json(<String, Object?>{
        'id': 'profile-1',
        'careblazers_user_id': 'user-1',
        'display_name': 'Caregiver_abc123',
        'avatar_url': null,
        'joined_at': '2026-05-30T12:00:00.000Z',
        'role': 'user',
      });
      final ForumApiClient client = buildClient(adapter);

      await client.bootstrapProfile();

      expect(adapter.lastRequest!.method, 'POST');
      expect(
        adapter.lastRequest!.uri.toString(),
        'https://forum-api.workers.dev/api/v1/profiles/bootstrap',
      );
      expect(
        adapter.lastRequest!.headers['Authorization'],
        'Bearer $fakeJwt',
      );
    });

    test('public GET /posts skips the Authorization header', () async {
      final _RecordingAdapter adapter =
          _RecordingAdapter.json(<String, Object?>{'posts': <Object?>[]});
      final ForumApiClient client = buildClient(adapter);

      await client.listPosts();

      expect(adapter.lastRequest!.method, 'GET');
      expect(
        adapter.lastRequest!.headers.containsKey('Authorization'),
        isFalse,
      );
    });

    test('public GET /posts/:id skips the Authorization header', () async {
      final _RecordingAdapter adapter = _RecordingAdapter.json(_samplePostJson(
        id: 'post-1',
      ));
      final ForumApiClient client = buildClient(adapter);
      await client.getPost('post-1');
      expect(
        adapter.lastRequest!.headers.containsKey('Authorization'),
        isFalse,
      );
    });

    test('public GET /posts/:id/comments skips the Authorization header',
        () async {
      final _RecordingAdapter adapter =
          _RecordingAdapter.json(<String, Object?>{'comments': <Object?>[]});
      final ForumApiClient client = buildClient(adapter);
      await client.listComments(postId: 'post-1');
      expect(
        adapter.lastRequest!.headers.containsKey('Authorization'),
        isFalse,
      );
    });

    test('token loader fires for protected requests, never on public reads',
        () async {
      final List<int> calls = <int>[];

      // Public path — empty feed, no auth call.
      final _RecordingAdapter publicAdapter =
          _RecordingAdapter.json(<String, Object?>{'posts': <Object?>[]});
      final ForumApiClient publicClient = buildClient(
        publicAdapter,
        tokenLoader: recordingTokenLoader(calls),
      );
      await publicClient.listPosts();
      await publicClient.listPosts();
      expect(calls, isEmpty,
          reason: 'public reads must not pay the token-loader round-trip');

      // Protected path — exactly one token resolution per request.
      final _RecordingAdapter authedAdapter =
          _RecordingAdapter.json(<String, Object?>{
        'id': 'profile-1',
        'careblazers_user_id': 'user-1',
        'display_name': 'Caregiver_abc123',
        'avatar_url': null,
        'joined_at': '2026-05-30T12:00:00.000Z',
        'role': 'user',
      });
      final ForumApiClient authedClient = buildClient(
        authedAdapter,
        tokenLoader: recordingTokenLoader(calls),
      );
      await authedClient.getMyProfile();
      expect(calls, hasLength(1));
    });
  });

  // ---- Google sign-in bootstrap (/auth/google) -----------------------------

  group('verifyGoogleIdToken — pre-auth bootstrap', () {
    test('POSTs {id_token} WITHOUT an Authorization header', () async {
      final _RecordingAdapter adapter =
          _RecordingAdapter.json(<String, Object?>{
        'user_id': 'spine-1',
        'email': 'real@gmail.com',
        'name': 'Real Caregiver',
        'username': null,
      });
      // Tokens must NEVER be pulled for this bootstrap — fail loudly if so.
      final ForumApiClient client = buildClient(
        adapter,
        tokenLoader: () async =>
            throw StateError('bootstrap must not pull a JWT'),
      );

      final GoogleAuthResult r = await client.verifyGoogleIdToken('g-id-token');

      expect(adapter.lastRequest!.method, 'POST');
      expect(adapter.lastRequest!.uri.toString(),
          'https://forum-api.workers.dev/api/v1/auth/google');
      expect(adapter.lastBody, <String, Object?>{'id_token': 'g-id-token'});
      expect(adapter.lastRequest!.headers.containsKey('Authorization'),
          isFalse);
      expect(r.userId, 'spine-1');
      expect(r.email, 'real@gmail.com');
      expect(r.name, 'Real Caregiver');
      expect(r.username, isNull);
    });

    test('parses a non-null username when the account has claimed one',
        () async {
      final _RecordingAdapter adapter =
          _RecordingAdapter.json(<String, Object?>{
        'user_id': 'spine-2',
        'email': 'mei@gmail.com',
        'name': 'Mei W.',
        'username': 'mei_w',
      });
      final ForumApiClient client = buildClient(adapter);

      final GoogleAuthResult r = await client.verifyGoogleIdToken('tok');
      expect(r.username, 'mei_w');
    });

    test('401 invalid_token surfaces a GoogleAuthException', () async {
      final _RecordingAdapter adapter = _RecordingAdapter.json(
        <String, Object?>{'error': 'invalid_token'},
        statusCode: 401,
      );
      final ForumApiClient client = buildClient(adapter);

      await expectLater(
        client.verifyGoogleIdToken('bad'),
        throwsA(isA<GoogleAuthException>()
            .having((GoogleAuthException e) => e.statusCode, 'statusCode', 401)
            .having(
                (GoogleAuthException e) => e.code, 'code', 'invalid_token')),
      );
    });

    test('400 missing_id_token surfaces a GoogleAuthException', () async {
      final _RecordingAdapter adapter = _RecordingAdapter.json(
        <String, Object?>{'error': 'missing_id_token'},
        statusCode: 400,
      );
      final ForumApiClient client = buildClient(adapter);

      await expectLater(
        client.verifyGoogleIdToken(''),
        throwsA(isA<GoogleAuthException>()
            .having((GoogleAuthException e) => e.statusCode, 'statusCode', 400)
            .having(
                (GoogleAuthException e) => e.code, 'code', 'missing_id_token')),
      );
    });
  });

  // ---- Request shapes ------------------------------------------------------

  group('Request shapes — Phase 13.9', () {
    test('createPost sends {title, body} as JSON', () async {
      final _RecordingAdapter adapter =
          _RecordingAdapter.json(_samplePostJson(id: 'post-1'));
      final ForumApiClient client = buildClient(adapter);

      await client.createPost(title: 'Sundowning advice', body: 'Body text');

      expect(adapter.lastBody, <String, Object?>{
        'title': 'Sundowning advice',
        'body': 'Body text',
      });
      expect(
        adapter.lastRequest!.headers[Headers.contentTypeHeader],
        Headers.jsonContentType,
      );
    });

    test('updateMyProfile only includes the fields explicitly passed',
        () async {
      final _RecordingAdapter adapter =
          _RecordingAdapter.json(<String, Object?>{
        'id': 'profile-1',
        'careblazers_user_id': 'user-1',
        'display_name': 'NewName',
        'avatar_url': null,
        'joined_at': '2026-05-30T12:00:00.000Z',
        'role': 'user',
      });
      final ForumApiClient client = buildClient(adapter);

      await client.updateMyProfile(displayName: 'NewName');

      expect(adapter.lastBody, <String, Object?>{'display_name': 'NewName'});
      expect(
        adapter.lastBody!.containsKey('avatar_url'),
        isFalse,
        reason: 'omitted-on-call fields should not surface as JSON null',
      );
    });

    test('listPosts encodes sort + before + limit on the query string',
        () async {
      final _RecordingAdapter adapter =
          _RecordingAdapter.json(<String, Object?>{'posts': <Object?>[]});
      final ForumApiClient client = buildClient(adapter);

      await client.listPosts(
        sort: ForumPostSort.newest,
        before: 'post-cursor',
        limit: 25,
      );

      final Uri uri = adapter.lastRequest!.uri;
      expect(uri.path, '/api/v1/posts');
      expect(uri.queryParameters['sort'], 'new');
      expect(uri.queryParameters['before'], 'post-cursor');
      expect(uri.queryParameters['limit'], '25');
    });

    test('castVote sends {target_kind, target_id, value}', () async {
      final _RecordingAdapter adapter =
          _RecordingAdapter.json(<String, Object?>{
        'vote_count': 7,
        'value': 1,
      });
      final ForumApiClient client = buildClient(adapter);

      final ForumVoteResponse vote = await client.castVote(
        targetKind: ForumVoteTarget.comment,
        targetId: 'comment-9',
        value: 1,
      );

      expect(adapter.lastBody, <String, Object?>{
        'target_kind': 'comment',
        'target_id': 'comment-9',
        'value': 1,
      });
      expect(vote.voteCount, 7);
      expect(vote.value, 1);
    });

    test('createComment includes parent_comment_id only when supplied',
        () async {
      final _RecordingAdapter adapter =
          _RecordingAdapter.json(_sampleCommentJson(
        id: 'comment-1',
        postId: 'post-1',
        parentCommentId: null,
      ));
      final ForumApiClient client = buildClient(adapter);

      await client.createComment(postId: 'post-1', body: 'reply');
      expect(adapter.lastBody, <String, Object?>{'body': 'reply'});

      await client.createComment(
        postId: 'post-1',
        body: 'nested',
        parentCommentId: 'parent-1',
      );
      expect(adapter.lastBody, <String, Object?>{
        'body': 'nested',
        'parent_comment_id': 'parent-1',
      });
    });

    test('reviewReport sends {action: <wire-value>}', () async {
      final Map<String, Object?> reportJson = _sampleReportJson(id: 'r-1');
      reportJson['action'] = 'ban_user';
      reportJson['banned_user_id'] = 'author-7';
      final _RecordingAdapter adapter = _RecordingAdapter.json(reportJson);
      final ForumApiClient client = buildClient(adapter);

      final ForumReportReviewResponse resp = await client.reviewReport(
        reportId: 'r-1',
        action: ForumReportAction.banUser,
      );

      expect(adapter.lastBody, <String, Object?>{'action': 'ban_user'});
      expect(resp.action, 'ban_user');
      expect(resp.bannedUserId, 'author-7');
      expect(resp.report.id, 'r-1');
    });
  });

  // ---- Response parsing ----------------------------------------------------

  group('Response parsing — Phase 13.9', () {
    test('listPosts returns parsed ForumPosts', () async {
      final _RecordingAdapter adapter =
          _RecordingAdapter.json(<String, Object?>{
        'posts': <Object?>[
          _samplePostJson(id: 'p-1'),
          _samplePostJson(id: 'p-2'),
        ],
      });
      final ForumApiClient client = buildClient(adapter);
      final List<ForumPost> posts = await client.listPosts();
      expect(posts.map((ForumPost p) => p.id).toList(),
          <String>['p-1', 'p-2']);
      // The denormalized author-name fields round-trip off the wire.
      expect(posts.first.authorUsername, 'sarah_h');
      expect(posts.first.authorDisplayName, 'Sarah_H');
    });

    test('listComments parses hidden rows with body=null', () async {
      final _RecordingAdapter adapter =
          _RecordingAdapter.json(<String, Object?>{
        'comments': <Object?>[
          _sampleCommentJson(id: 'c-1', postId: 'p-1'),
          <String, Object?>{
            'id': 'c-2',
            'post_id': 'p-1',
            'parent_comment_id': 'c-1',
            'author_id': null,
            'body': null,
            'created_at': '2026-05-30T12:00:00.000Z',
            'vote_count': 0,
            'depth': 1,
            'hidden': true,
          },
        ],
      });
      final ForumApiClient client = buildClient(adapter);

      final List<ForumComment> comments =
          await client.listComments(postId: 'p-1');

      expect(comments, hasLength(2));
      // Visible row carries the denormalized author-name fields.
      expect(comments[0].authorUsername, 'sarah_h');
      expect(comments[0].authorDisplayName, 'Sarah_H');
      expect(comments[1].hidden, isTrue);
      expect(comments[1].body, isNull);
      expect(comments[1].authorId, isNull);
      // Tree shape still intact — depth + parent ref survive.
      expect(comments[1].parentCommentId, 'c-1');
      expect(comments[1].depth, 1);
    });

    test('createPost splits crisis_resources off the post envelope',
        () async {
      final Map<String, Object?> body = _samplePostJson(id: 'p-1');
      body['crisis_resources'] = <String, Object?>{
        'crisis_card_url': '/crisis',
        'hotlines': <Object?>[
          <String, Object?>{
            'label': '988 Suicide & Crisis Lifeline',
            'number': '988',
            'description': '24/7 confidential support.',
          },
        ],
      };
      final _RecordingAdapter adapter = _RecordingAdapter.json(body);
      final ForumApiClient client = buildClient(adapter);

      final ForumCreatePostResponse resp = await client.createPost(
        title: 't',
        body: 'b',
      );

      expect(resp.post.id, 'p-1');
      expect(resp.crisisResources, isNotNull);
      expect(resp.crisisResources!.crisisCardUrl, '/crisis');
      expect(resp.crisisResources!.hotlines.single.number, '988');
    });

    test('createPost without crisis_resources returns crisisResources=null',
        () async {
      final _RecordingAdapter adapter =
          _RecordingAdapter.json(_samplePostJson(id: 'p-1'));
      final ForumApiClient client = buildClient(adapter);
      final ForumCreatePostResponse resp =
          await client.createPost(title: 't', body: 'b');
      expect(resp.crisisResources, isNull);
    });

    test('createComment splits crisis_resources off the comment envelope',
        () async {
      final Map<String, Object?> body =
          _sampleCommentJson(id: 'c-1', postId: 'p-1');
      body['crisis_resources'] = <String, Object?>{
        'crisis_card_url': '/crisis',
        'hotlines': <Object?>[],
      };
      final _RecordingAdapter adapter = _RecordingAdapter.json(body);
      final ForumApiClient client = buildClient(adapter);

      final ForumCreateCommentResponse resp = await client.createComment(
        postId: 'p-1',
        body: 'I need help',
      );
      expect(resp.comment.id, 'c-1');
      expect(resp.crisisResources, isNotNull);
    });
  });

  // ---- Error surfacing -----------------------------------------------------

  group('Error surfacing — Phase 13.9', () {
    test('non-2xx response raises ForumApiException with the error code',
        () async {
      final _RecordingAdapter adapter = _RecordingAdapter.json(
        <String, Object?>{'error': 'invalid_title'},
        statusCode: 400,
      );
      final ForumApiClient client = buildClient(adapter);

      await expectLater(
        client.createPost(title: '', body: 'b'),
        throwsA(isA<ForumApiException>()
            .having(
                (ForumApiException e) => e.statusCode, 'statusCode', 400)
            .having(
                (ForumApiException e) => e.error, 'error', 'invalid_title')),
      );
    });

    test('401 with Token-Expired: true sets tokenExpired=true', () async {
      final _RecordingAdapter adapter = _RecordingAdapter.json(
        <String, Object?>{'error': 'token_expired'},
        statusCode: 401,
        extraHeaders: <String, List<String>>{
          'token-expired': <String>['true'],
        },
      );
      final ForumApiClient client = buildClient(adapter);

      try {
        await client.getMyProfile();
        fail('expected ForumApiException');
      } on ForumApiException catch (e) {
        expect(e.statusCode, 401);
        expect(e.tokenExpired, isTrue);
      }
    });

    test('transport-level DioException becomes a ForumApiException', () async {
      final ForumApiClient client = ForumApiClient(
        tokenLoader: () async => fakeJwt,
        dio: Dio()..httpClientAdapter = _ThrowingAdapter(),
        baseUrl: 'https://forum-api.workers.dev',
      );
      await expectLater(
        client.getMyProfile(),
        throwsA(isA<ForumApiException>()),
      );
    });

    test('unexpected response shape (string body) surfaces a 0/error', () async {
      final _RecordingAdapter adapter = _RecordingAdapter.raw(
        body: utf8.encode('"just-a-string"'),
        statusCode: 200,
      );
      final ForumApiClient client = buildClient(adapter);
      await expectLater(
        client.getMyProfile(),
        throwsA(isA<ForumApiException>().having(
            (ForumApiException e) => e.error,
            'error',
            contains('unexpected_response_shape'))),
      );
    });
  });

  // ---- Username + circles (care-circle connect, 2026-06-06) ---------------

  group('Username + circles — care-circle connect', () {
    test('usernameAvailable encodes ?u= and parses {valid, available}',
        () async {
      final _RecordingAdapter adapter = _RecordingAdapter.json(
        <String, Object?>{'valid': true, 'available': false},
      );
      final ForumApiClient client = buildClient(adapter);

      final ({bool valid, bool available}) result =
          await client.usernameAvailable('sarah_h');

      expect(adapter.lastRequest!.uri.path,
          '/api/v1/profiles/username-available');
      expect(adapter.lastRequest!.uri.queryParameters['u'], 'sarah_h');
      expect(result.valid, isTrue);
      expect(result.available, isFalse);
    });

    test('updateMyProfile sends username when supplied', () async {
      final _RecordingAdapter adapter =
          _RecordingAdapter.json(<String, Object?>{
        'id': 'profile-1',
        'careblazers_user_id': 'user-1',
        'display_name': 'Caregiver',
        'avatar_url': null,
        'joined_at': '2026-05-30T12:00:00.000Z',
        'role': 'user',
        'username': 'sarah_h',
      });
      final ForumApiClient client = buildClient(adapter);

      final ForumProfile profile =
          await client.updateMyProfile(username: 'sarah_h');

      expect(adapter.lastBody, <String, Object?>{'username': 'sarah_h'});
      expect(profile.username, 'sarah_h');
    });

    test('PATCH username 409 surfaces username_taken', () async {
      final _RecordingAdapter adapter = _RecordingAdapter.json(
        <String, Object?>{'error': 'username_taken'},
        statusCode: 409,
      );
      final ForumApiClient client = buildClient(adapter);

      await expectLater(
        client.updateMyProfile(username: 'taken'),
        throwsA(isA<ForumApiException>()
            .having((ForumApiException e) => e.statusCode, 'statusCode', 409)
            .having(
                (ForumApiException e) => e.error, 'error', 'username_taken')),
      );
    });

    test('getProfileByUsername parses the lean public profile', () async {
      final _RecordingAdapter adapter =
          _RecordingAdapter.json(<String, Object?>{
        'id': 'profile-9',
        'username': 'mei_w',
        'display_name': 'Mei W.',
        'avatar_url': null,
      });
      final ForumApiClient client = buildClient(adapter);

      final ForumPublicProfile p = await client.getProfileByUsername('mei_w');

      expect(adapter.lastRequest!.uri.path,
          '/api/v1/profiles/by-username/mei_w');
      expect(p.id, 'profile-9');
      expect(p.username, 'mei_w');
      expect(p.displayName, 'Mei W.');
      // Lean lookup omits joined_at + counts — they default cleanly.
      expect(p.joinedAt, isNull);
      expect(p.postCount, 0);
    });

    test('getProfileByUsername 404 surfaces profile_not_found', () async {
      final _RecordingAdapter adapter = _RecordingAdapter.json(
        <String, Object?>{'error': 'profile_not_found'},
        statusCode: 404,
      );
      final ForumApiClient client = buildClient(adapter);

      await expectLater(
        client.getProfileByUsername('nobody'),
        throwsA(isA<ForumApiException>().having(
            (ForumApiException e) => e.error, 'error', 'profile_not_found')),
      );
    });

    test('createCircle sends {name} and parses members', () async {
      final _RecordingAdapter adapter =
          _RecordingAdapter.json(<String, Object?>{
        'id': 'circle-1',
        'name': "Sarah's circle",
        'owner_profile_id': 'profile-1',
        'created_at': '2026-06-06T12:00:00.000Z',
        'members': <Object?>[
          <String, Object?>{
            'profile_id': 'profile-1',
            'username': 'sarah_h',
            'display_name': 'Sarah',
            'role': 'owner',
          },
        ],
      });
      final ForumApiClient client = buildClient(adapter);

      final CircleDto circle = await client.createCircle("Sarah's circle");

      expect(adapter.lastBody, <String, Object?>{'name': "Sarah's circle"});
      expect(circle.id, 'circle-1');
      expect(circle.ownerProfileId, 'profile-1');
      expect(circle.members.single.role, 'owner');
      expect(circle.members.single.username, 'sarah_h');
    });

    test('listCircles unwraps the {circles:[]} envelope', () async {
      final _RecordingAdapter adapter =
          _RecordingAdapter.json(<String, Object?>{
        'circles': <Object?>[
          <String, Object?>{
            'id': 'circle-1',
            'name': 'C1',
            'owner_profile_id': 'profile-1',
            'created_at': '2026-06-06T12:00:00.000Z',
            'members': <Object?>[],
          },
        ],
      });
      final ForumApiClient client = buildClient(adapter);

      final List<CircleDto> circles = await client.listCircles();

      expect(adapter.lastRequest!.uri.path, '/api/v1/circles');
      expect(circles, hasLength(1));
      expect(circles.single.id, 'circle-1');
    });

    test('createInvite parses {token, circle_id, expires_at}', () async {
      final _RecordingAdapter adapter =
          _RecordingAdapter.json(<String, Object?>{
        'token': 'inv-abc',
        'circle_id': 'circle-1',
        'expires_at': '2026-06-13T12:00:00.000Z',
      });
      final ForumApiClient client = buildClient(adapter);

      final CircleInviteDto invite = await client.createInvite('circle-1');

      expect(adapter.lastRequest!.uri.path,
          '/api/v1/circles/circle-1/invites');
      expect(invite.token, 'inv-abc');
      expect(invite.circleId, 'circle-1');
    });

    test('joinCircle sends {token} and parses the circle', () async {
      final _RecordingAdapter adapter =
          _RecordingAdapter.json(<String, Object?>{
        'id': 'circle-1',
        'name': 'C1',
        'owner_profile_id': 'profile-1',
        'created_at': '2026-06-06T12:00:00.000Z',
        'members': <Object?>[],
      });
      final ForumApiClient client = buildClient(adapter);

      final CircleDto circle = await client.joinCircle('inv-abc');

      expect(adapter.lastRequest!.uri.path, '/api/v1/circles/join');
      expect(adapter.lastBody, <String, Object?>{'token': 'inv-abc'});
      expect(circle.id, 'circle-1');
    });

    test('joinCircle 410 surfaces invite_expired', () async {
      final _RecordingAdapter adapter = _RecordingAdapter.json(
        <String, Object?>{'error': 'invite_expired'},
        statusCode: 410,
      );
      final ForumApiClient client = buildClient(adapter);

      await expectLater(
        client.joinCircle('stale'),
        throwsA(isA<ForumApiException>()
            .having((ForumApiException e) => e.statusCode, 'statusCode', 410)
            .having(
                (ForumApiException e) => e.error, 'error', 'invite_expired')),
      );
    });
  });

  // ---- Enum wire encodings -------------------------------------------------

  group('wire-value enums', () {
    test('ForumPostSort renames newest → "new"', () {
      expect(ForumPostSort.hot.queryValue, 'hot');
      expect(ForumPostSort.newest.queryValue, 'new');
      expect(ForumPostSort.top.queryValue, 'top');
    });

    test('ForumCommentSort renames newest → "new"', () {
      expect(ForumCommentSort.top.queryValue, 'top');
      expect(ForumCommentSort.newest.queryValue, 'new');
    });

    test('ForumVoteTarget matches backend constants', () {
      expect(ForumVoteTarget.post.queryValue, 'post');
      expect(ForumVoteTarget.comment.queryValue, 'comment');
    });

    test('ForumReportAction matches backend REPORT_ACTIONS', () {
      expect(ForumReportAction.noAction.queryValue, 'no_action');
      expect(ForumReportAction.hideTarget.queryValue, 'hide_target');
      expect(ForumReportAction.banUser.queryValue, 'ban_user');
    });
  });
}

Map<String, Object?> _samplePostJson({required String id}) =>
    <String, Object?>{
      'id': id,
      'author_id': 'profile-1',
      'author_username': 'sarah_h',
      'author_display_name': 'Sarah_H',
      'title': 'Some title',
      'body': 'Some body',
      'created_at': '2026-05-30T12:00:00.000Z',
      'updated_at': '2026-05-30T12:00:00.000Z',
      'vote_count': 0,
      'hidden': false,
      'crisis_flagged': false,
    };

Map<String, Object?> _sampleCommentJson({
  required String id,
  required String postId,
  String? parentCommentId,
}) =>
    <String, Object?>{
      'id': id,
      'post_id': postId,
      'parent_comment_id': parentCommentId,
      'author_id': 'profile-1',
      'author_username': 'sarah_h',
      'author_display_name': 'Sarah_H',
      'body': 'A comment',
      'created_at': '2026-05-30T12:00:00.000Z',
      'vote_count': 0,
      'depth': parentCommentId == null ? 0 : 1,
      'hidden': false,
      'crisis_flagged': false,
    };

Map<String, Object?> _sampleReportJson({required String id}) =>
    <String, Object?>{
      'id': id,
      'target_kind': 'post',
      'target_id': 'post-1',
      'reporter_id': 'profile-1',
      'reason': 'spam',
      'status': 'actioned',
      'created_at': '2026-05-30T12:00:00.000Z',
      'resolved_at': '2026-05-30T12:30:00.000Z',
    };

/// HttpClientAdapter that records the request + replays a canned
/// response. Modeled on `test/services/chat_service_test.dart`'s
/// `_CannedSseAdapter` — the codebase prefers Dio adapter injection
/// over a mocking library since the seam is already injectable.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter._({
    required this.bodyBytes,
    required this.statusCode,
    required this.contentType,
    this.extraHeaders = const <String, List<String>>{},
  });

  factory _RecordingAdapter.json(
    Object jsonBody, {
    int statusCode = 200,
    Map<String, List<String>> extraHeaders = const <String, List<String>>{},
  }) {
    final List<int> bytes = utf8.encode(json.encode(jsonBody));
    return _RecordingAdapter._(
      bodyBytes: bytes,
      statusCode: statusCode,
      contentType: Headers.jsonContentType,
      extraHeaders: extraHeaders,
    );
  }

  factory _RecordingAdapter.raw({
    required List<int> body,
    int statusCode = 200,
    String contentType = Headers.jsonContentType,
  }) {
    return _RecordingAdapter._(
      bodyBytes: body,
      statusCode: statusCode,
      contentType: contentType,
    );
  }

  final List<int> bodyBytes;
  final int statusCode;
  final String contentType;
  final Map<String, List<String>> extraHeaders;

  RequestOptions? lastRequest;
  Map<String, Object?>? lastBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    if (options.data is Map) {
      lastBody = Map<String, Object?>.from(options.data as Map);
    } else if (requestStream != null) {
      final List<int> collected = <int>[];
      await for (final Uint8List part in requestStream) {
        collected.addAll(part);
      }
      if (collected.isNotEmpty) {
        try {
          final dynamic decoded = json.decode(utf8.decode(collected));
          if (decoded is Map) {
            lastBody = Map<String, Object?>.from(decoded);
          }
        } on FormatException {
          // Body wasn't JSON — leave lastBody null.
        }
      }
    }

    return ResponseBody.fromBytes(
      bodyBytes,
      statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[contentType],
        ...extraHeaders,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A canned response for [_SequenceAdapter].
class _CannedResponse {
  _CannedResponse.json(
    Object jsonBody, {
    this.statusCode = 200,
    this.extraHeaders = const <String, List<String>>{},
  }) : bodyBytes = utf8.encode(json.encode(jsonBody));

  final List<int> bodyBytes;
  final int statusCode;
  final Map<String, List<String>> extraHeaders;
}

/// HttpClientAdapter replaying a SEQUENCE of canned responses (one per
/// request, in order) — used for the expired-token retry contract where
/// the first call 401s and the retry succeeds.
class _SequenceAdapter implements HttpClientAdapter {
  _SequenceAdapter(this.responses);

  final List<_CannedResponse> responses;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final _CannedResponse canned = responses[
        requests.length <= responses.length
            ? requests.length - 1
            : responses.length - 1];
    return ResponseBody.fromBytes(
      canned.bodyBytes,
      canned.statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        ...canned.extraHeaders,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return Future<ResponseBody>.error(
      DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: 'connection refused',
      ),
    );
  }

  @override
  void close({bool force = false}) {}
}

