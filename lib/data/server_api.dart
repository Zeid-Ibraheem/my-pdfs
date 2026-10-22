import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Erreur lisible renvoyée à l'écran (serveur injoignable, jeton refusé…).
class ServerException implements Exception {
  const ServerException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Un livre stocké sur le serveur.
class RemoteBook {
  const RemoteBook({
    required this.id,
    required this.title,
    required this.sizeBytes,
    required this.pageCount,
    required this.addedAt,
    required this.textStatus,
  });

  final String id;
  final String title;
  final int sizeBytes;
  final int? pageCount;
  final DateTime addedAt;

  /// « pending » (en cours), « done », « none » (scan sans texte), « error ».
  final String textStatus;

  factory RemoteBook.fromJson(Map<String, dynamic> json) => RemoteBook(
        id: json['id'] as String,
        title: json['title'] as String? ?? 'Sans titre',
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        pageCount: (json['page_count'] as num?)?.toInt(),
        addedAt: DateTime.fromMillisecondsSinceEpoch(
            (json['added_at'] as num?)?.toInt() ?? 0),
        textStatus: json['text_status'] as String? ?? 'pending',
      );
}

/// Place utilisée sur le serveur.
class ServerUsage {
  const ServerUsage({
    required this.usedBytes,
    required this.quotaBytes,
    required this.books,
    required this.textPending,
  });

  final int usedBytes;
  final int quotaBytes;
  final int books;
  final int textPending;

  factory ServerUsage.fromJson(Map<String, dynamic> json) => ServerUsage(
        usedBytes: (json['used_bytes'] as num?)?.toInt() ?? 0,
        quotaBytes: (json['quota_bytes'] as num?)?.toInt() ?? 0,
        books: (json['books'] as num?)?.toInt() ?? 0,
        textPending: (json['text_pending'] as num?)?.toInt() ?? 0,
      );
}

/// Un passage trouvé par la recherche plein texte.
class SearchHit {
  const SearchHit({
    required this.bookId,
    required this.title,
    required this.page,
    required this.snippet,
  });

  final String bookId;
  final String title;
  final int page;

  /// Extrait de texte ; les mots trouvés sont entourés de \u0001 et \u0002.
  final String snippet;

  factory SearchHit.fromJson(Map<String, dynamic> json) => SearchHit(
        bookId: json['book_id'] as String,
        title: json['title'] as String? ?? '',
        page: (json['page'] as num).toInt(),
        snippet: json['snippet'] as String? ?? '',
      );
}

/// Un résultat de la recherche de livres en ligne.
class DiscoverResult {
  const DiscoverResult({
    required this.source,
    required this.id,
    required this.title,
    required this.authors,
    required this.year,
    required this.status,
    required this.url,
    required this.origin,
  });

  /// « ia » (Internet Archive), « openlibrary » ou « gallica ».
  final String source;
  final String id;
  final String title;
  final String authors;
  final String year;

  /// « download » (libre, importable), « borrow » (empruntable : lien),
  /// « link » (à consulter sur le site).
  final String status;
  final String url;

  /// Site où le livre a été trouvé (affichage).
  final String origin;

  factory DiscoverResult.fromJson(Map<String, dynamic> json) => DiscoverResult(
        source: json['source'] as String? ?? '',
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? 'Sans titre',
        authors: json['authors'] as String? ?? '',
        year: '${json['year'] ?? ''}',
        status: json['status'] as String? ?? 'link',
        url: json['url'] as String? ?? '',
        origin: json['origin'] as String? ?? '',
      );
}

class DiscoverResponse {
  const DiscoverResponse(this.results, this.errors);

  final List<DiscoverResult> results;
  final List<String> errors;
}

class BackupInfo {
  const BackupInfo(this.name, this.sizeBytes, this.createdAt);

  final String name;
  final int sizeBytes;
  final DateTime createdAt;

  factory BackupInfo.fromJson(Map<String, dynamic> json) => BackupInfo(
        json['name'] as String,
        (json['size_bytes'] as num).toInt(),
        DateTime.fromMillisecondsSinceEpoch((json['created_at'] as num).toInt()),
      );
}

typedef ProgressCallback = void Function(double fraction);

/// Client de l'API du serveur My PDFs (voir server/README.md).
class ServerApi {
  ServerApi({required this.baseUrl, required this.token});

  /// Ex. « http://100.101.102.103:8765 » (adresse Tailscale du serveur).
  final String baseUrl;
  final String token;
  final http.Client _client = http.Client();

  static const _shortTimeout = Duration(seconds: 20);

  Map<String, String> get _auth => {'Authorization': 'Bearer $token'};

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$baseUrl$path');
    return query == null ? uri : uri.replace(queryParameters: query);
  }

  /// Transforme les erreurs réseau en messages compréhensibles.
  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on ServerException {
      rethrow;
    } on TimeoutException {
      throw const ServerException(
          'Le serveur met trop de temps à répondre (Tailscale activé ?)');
    } on SocketException {
      throw const ServerException(
          'Serveur injoignable : vérifie que Tailscale est activé sur le '
          'téléphone et que le serveur est allumé');
    } on http.ClientException catch (e) {
      // Les erreurs de connexion (serveur éteint, Tailscale coupé…)
      // arrivent ici dans les versions récentes du paquet http.
      throw ServerException(
          'Serveur injoignable (Tailscale activé ? serveur allumé ?) : '
          '${e.message}');
    } on FormatException {
      throw const ServerException('Réponse inattendue du serveur');
    }
  }

  void _check(int status, List<int> body) {
    if (status >= 200 && status < 300) return;
    var detail = utf8.decode(body, allowMalformed: true);
    try {
      final json = jsonDecode(detail);
      if (json is Map && json['detail'] is String) {
        detail = json['detail'] as String;
      }
    } catch (_) {
      // Pas du JSON : on garde le texte brut.
    }
    if (status == 401) {
      throw const ServerException('Jeton refusé par le serveur');
    }
    throw ServerException(detail.isEmpty ? 'Erreur $status du serveur' : detail);
  }

  Future<dynamic> _getJson(
    String path, {
    Map<String, String>? query,
    Duration timeout = _shortTimeout,
  }) {
    return _guard(() async {
      final response =
          await _client.get(_uri(path, query), headers: _auth).timeout(timeout);
      _check(response.statusCode, response.bodyBytes);
      return jsonDecode(utf8.decode(response.bodyBytes));
    });
  }

  // ------------------------------------------------------------- Général

  /// Vérifie que le serveur répond et que le jeton est bon.
  Future<ServerUsage> check() async {
    await _guard(() async {
      final response =
          await _client.get(_uri('/api/health')).timeout(_shortTimeout);
      _check(response.statusCode, response.bodyBytes);
    });
    return usage();
  }

  Future<ServerUsage> usage() async =>
      ServerUsage.fromJson(await _getJson('/api/usage') as Map<String, dynamic>);

  // -------------------------------------------------------------- Livres

  Future<List<RemoteBook>> books() async {
    final list = await _getJson('/api/books') as List<dynamic>;
    return [
      for (final item in list) RemoteBook.fromJson(item as Map<String, dynamic>),
    ];
  }

  /// Envoie un PDF. Le serveur vérifie qu'il correspond bien à [id].
  Future<void> upload(
    String id,
    String title,
    File file, {
    ProgressCallback? onProgress,
  }) {
    return _guard(() async {
      final length = await file.length();
      final request = http.StreamedRequest(
        'PUT',
        _uri('/api/books/$id', {'title': title}),
      )
        ..headers.addAll(_auth)
        ..headers['Content-Type'] = 'application/pdf'
        ..contentLength = length;
      final responseFuture = _client.send(request);
      var sent = 0;
      await request.sink.addStream(file.openRead().map((chunk) {
        sent += chunk.length;
        if (length > 0) onProgress?.call(sent / length);
        return chunk;
      }));
      await request.sink.close();
      final response = await http.Response.fromStream(await responseFuture);
      _check(response.statusCode, response.bodyBytes);
    });
  }

  /// Télécharge un PDF dans [dest] et vérifie son empreinte.
  Future<void> download(
    String id,
    File dest, {
    int? expectedSize,
    ProgressCallback? onProgress,
  }) {
    return _guard(() async {
      final request = http.Request('GET', _uri('/api/books/$id/file'))
        ..headers.addAll(_auth);
      final response = await _client.send(request);
      if (response.statusCode != 200) {
        _check(response.statusCode, await response.stream.toBytes());
      }
      final total = response.contentLength ?? expectedSize ?? 0;
      final sink = dest.openWrite();
      final hashInput = StreamController<List<int>>();
      final digestFuture = sha256.bind(hashInput.stream).first;
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          hashInput.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress?.call(received / total);
        }
      } finally {
        await sink.close();
        await hashInput.close();
      }
      final digest = (await digestFuture).toString();
      if (digest != id) {
        await dest.delete();
        throw const ServerException(
            'Fichier abîmé pendant le téléchargement : réessaie');
      }
    });
  }

  Future<void> rename(String id, String title) {
    return _guard(() async {
      final response = await _client
          .patch(
            _uri('/api/books/$id'),
            headers: {..._auth, 'Content-Type': 'application/json'},
            body: jsonEncode({'title': title}),
          )
          .timeout(_shortTimeout);
      _check(response.statusCode, response.bodyBytes);
    });
  }

  Future<void> delete(String id) {
    return _guard(() async {
      final response = await _client
          .delete(_uri('/api/books/$id'), headers: _auth)
          .timeout(_shortTimeout);
      if (response.statusCode == 404) return; // déjà supprimé
      _check(response.statusCode, response.bodyBytes);
    });
  }

  // ------------------------------------------------------------ Recherche

  Future<List<SearchHit>> search(String query) async {
    final list = await _getJson('/api/search', query: {'q': query})
        as List<dynamic>;
    return [
      for (final item in list) SearchHit.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<DiscoverResponse> discover(String query) async {
    final json = await _getJson(
      '/api/discover',
      query: {'q': query},
      timeout: const Duration(seconds: 45),
    ) as Map<String, dynamic>;
    return DiscoverResponse(
      [
        for (final item in json['results'] as List<dynamic>)
          DiscoverResult.fromJson(item as Map<String, dynamic>),
      ],
      [for (final e in json['errors'] as List<dynamic>) '$e'],
    );
  }

  /// Demande au serveur de télécharger un livre libre (il le garde ensuite).
  Future<RemoteBook> importDiscovered(DiscoverResult result) {
    return _guard(() async {
      final response = await _client
          .post(
            _uri('/api/discover/import'),
            headers: {..._auth, 'Content-Type': 'application/json'},
            body: jsonEncode(
                {'source': result.source, 'id': result.id, 'title': result.title}),
          )
          .timeout(const Duration(minutes: 15));
      _check(response.statusCode, response.bodyBytes);
      return RemoteBook.fromJson(
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>);
    });
  }

  // ---------------------------------------------------------- Sauvegardes

  Future<void> uploadBackup(File file) {
    return _guard(() async {
      final request = http.StreamedRequest('PUT', _uri('/api/backup'))
        ..headers.addAll(_auth)
        ..contentLength = await file.length();
      final responseFuture = _client.send(request);
      await request.sink.addStream(file.openRead());
      await request.sink.close();
      final response = await http.Response.fromStream(await responseFuture);
      _check(response.statusCode, response.bodyBytes);
    });
  }

  Future<List<BackupInfo>> backups() async {
    final list = await _getJson('/api/backups') as List<dynamic>;
    return [
      for (final item in list) BackupInfo.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<void> downloadLatestBackup(File dest) {
    return _guard(() async {
      final response = await _client
          .get(_uri('/api/backup/latest'), headers: _auth)
          .timeout(const Duration(minutes: 2));
      _check(response.statusCode, response.bodyBytes);
      await dest.writeAsBytes(response.bodyBytes, flush: true);
    });
  }
}
