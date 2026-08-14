import 'package:tldts/data/trie.dart' as psl_data;

bool cookiePathMatches(String requestPath, String? cookiePath) {
  final normalizedRequestPath = requestPath.isEmpty ? '/' : requestPath;
  final normalizedCookiePath = (cookiePath == null || cookiePath.isEmpty)
      ? '/'
      : cookiePath;

  if (normalizedRequestPath == normalizedCookiePath ||
      normalizedCookiePath == '/') {
    return true;
  }
  if (!normalizedRequestPath.startsWith(normalizedCookiePath)) {
    return false;
  }
  return normalizedCookiePath.endsWith('/') ||
      normalizedRequestPath.length > normalizedCookiePath.length &&
          normalizedRequestPath[normalizedCookiePath.length] == '/';
}

String defaultCookiePath(String requestPath) {
  if (requestPath.isEmpty || !requestPath.startsWith('/')) return '/';
  final lastSlash = requestPath.lastIndexOf('/');
  if (lastSlash <= 0) return '/';
  return requestPath.substring(0, lastSlash);
}

bool cookieDomainAttributeIsSafe(String responseHost, String domain) {
  final normalizedHost = canonicalHostOnlyCookieDomain(responseHost);
  final normalizedDomain = canonicalCookieDomainAttribute(domain);
  if (normalizedHost == null || normalizedDomain == null) return false;
  if (_isIpAddress(normalizedHost) || _isIpAddress(normalizedDomain)) {
    return false;
  }
  return (normalizedHost == normalizedDomain ||
          normalizedHost.endsWith('.$normalizedDomain')) &&
      isRegistrableCookieDomain(normalizedDomain);
}

bool cookieDomainMatches(
  String requestHost,
  String? cookieDomain, {
  bool hostOnly = true,
}) {
  final host = canonicalHostOnlyCookieDomain(requestHost);
  final domain = canonicalHostOnlyCookieDomain(cookieDomain);
  if (host == null || domain == null) return false;
  return host == domain ||
      (!hostOnly &&
          host.endsWith('.$domain') &&
          isRegistrableCookieDomain(domain));
}

String? canonicalCookieDomainAttribute(Object? rawDomain) {
  if (rawDomain is! String || rawDomain.isEmpty) return null;
  if (rawDomain != rawDomain.trim() || rawDomain.endsWith('.')) return null;
  final withoutLeadingDots = rawDomain.replaceFirst(RegExp(r'^\.+'), '');
  return canonicalHostOnlyCookieDomain(withoutLeadingDots);
}

bool isRegistrableCookieDomain(String domain) {
  final canonical = canonicalHostOnlyCookieDomain(domain);
  if (canonical == null || _isIpAddress(canonical)) return false;
  final labels = canonical.split('.');
  // tldts 0.0.1-beta exposes its bundled PSL trie, but its public options
  // currently build an incorrect enum-index bitmask for private rules. Query
  // both ICANN (1) and private (2) trie flags directly so hosts such as
  // github.io cannot be treated as registrable cookie scopes.
  const allRuleTypesMask = 1 | 2;
  final exception = _lookupPublicSuffixTrie(
    labels,
    psl_data.exceptions,
    labels.length - 1,
    allRuleTypesMask,
  );
  final suffixStart = exception == null
      ? _lookupPublicSuffixTrie(
              labels,
              psl_data.rules,
              labels.length - 1,
              allRuleTypesMask,
            )?.index ??
            labels.length - 1
      : exception.index + 1;
  return suffixStart > 0;
}

_PublicSuffixMatch? _lookupPublicSuffixTrie(
  List<String> labels,
  List<dynamic>? trie,
  int index,
  int allowedMask,
) {
  _PublicSuffixMatch? result;
  var node = trie;
  while (node != null) {
    final flags = node[0] as int;
    if (flags & allowedMask != 0) {
      result = _PublicSuffixMatch(index + 1);
    }
    if (index == -1) break;
    final children = node[1] as Map<String, dynamic>;
    node = (children[labels[index]] ?? children['*']) as List<dynamic>?;
    index--;
  }
  return result;
}

class _PublicSuffixMatch {
  const _PublicSuffixMatch(this.index);

  final int index;
}

/// Returns a canonical host for cookie matching and storage.
///
/// Legacy database rows without an explicit host-only flag are migrated as
/// host-only cookies; only newly received Domain attributes are PSL-validated.
String? canonicalHostOnlyCookieDomain(Object? rawDomain) {
  if (rawDomain is! String || rawDomain.isEmpty) return null;
  if (rawDomain != rawDomain.trim() ||
      rawDomain.startsWith('.') ||
      rawDomain.endsWith('.') ||
      rawDomain.codeUnits.any((unit) => unit <= 0x20 || unit == 0x7f)) {
    return null;
  }

  final domain = rawDomain.toLowerCase();
  if (domain.contains(':')) {
    if (!RegExp(r'^[0-9a-f:.]+$').hasMatch(domain)) return null;
    final uri = Uri.tryParse('http://[$domain]/');
    return uri != null && uri.host.toLowerCase() == domain ? domain : null;
  }

  if (RegExp(r'^[0-9.]+$').hasMatch(domain)) {
    final octets = domain.split('.');
    if (octets.length != 4 ||
        octets.any((octet) {
          final value = int.tryParse(octet);
          return octet.isEmpty || value == null || value > 255;
        })) {
      return null;
    }
    return domain;
  }

  if (domain.length > 253 ||
      domain
          .split('.')
          .any(
            (label) =>
                label.isEmpty ||
                label.length > 63 ||
                !RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label),
          )) {
    return null;
  }
  return domain;
}

bool cookieCanBeSent({
  required Uri requestUri,
  required String? cookieDomain,
  required String? cookiePath,
  required bool secure,
  bool hostOnly = true,
}) {
  if (secure && requestUri.scheme.toLowerCase() != 'https') return false;
  return cookieDomainMatches(
        requestUri.host,
        cookieDomain,
        hostOnly: hostOnly,
      ) &&
      cookiePathMatches(requestUri.path, cookiePath);
}

/// Applies the secure-origin and cookie-name prefix requirements while a
/// Set-Cookie value is being accepted.
bool cookieCanBeStored({
  required Uri responseUri,
  required String name,
  required bool secure,
  required String? domain,
  required String? path,
}) {
  final secureOrigin = responseUri.scheme.toLowerCase() == 'https';
  if (secure && !secureOrigin) return false;

  if (name.startsWith('__Secure-')) {
    return secure && secureOrigin;
  }
  if (name.startsWith('__Host-')) {
    return secure && secureOrigin && domain == null && path == '/';
  }
  return true;
}

bool _isIpAddress(String value) =>
    value.contains(':') || RegExp(r'^\d+(?:\.\d+){3}$').hasMatch(value);
