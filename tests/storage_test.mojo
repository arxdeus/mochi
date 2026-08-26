from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from mochi.storage import (
    AuthRecord,
    MakiId,
    McpAuthData,
    OAuthTokens,
    SessionRef,
    StorageError,
    StoragePaths,
    auth_record_from_json,
    auth_record_to_json,
    delete_mcp_auth,
    delete_provider_credentials,
    load_mcp_auth,
    load_provider_credentials,
    mcp_auth_path,
    provider_credentials_path,
    save_mcp_auth,
    save_provider_credentials,
    decode_base58,
    encode_base58,
    oauth_tokens_from_json,
    oauth_tokens_to_json,
)


comptime SAMPLE_UUID = "01965087-4c71-7f00-8000-000000000000"


def test_storage_error_tags() raises:
    assert_equal(StorageError.home_not_set().tag, StorageError.HOME_NOT_SET)
    assert_equal(StorageError.io("disk").message, "disk")
    assert_equal(StorageError.not_found("session").message, "not found: session")


def test_storage_paths_explicit_xdg_roots() raises:
    var paths = StoragePaths.from_roots(
        "/home/test",
        "/cfg",
        "/data",
        "/state",
        "/cache",
    )
    assert_equal(paths.config, "/cfg/maki")
    assert_equal(paths.data, "/data/maki")
    assert_equal(paths.state, "/state/maki")
    assert_equal(paths.logs, "/logs/maki")
    assert_equal(paths.cache, "/cache/maki")
    assert_equal(paths.xdg_config, "/cfg/maki")


def test_storage_paths_defaults_and_legacy_fallback() raises:
    var paths = StoragePaths.from_roots("/home/test", "", "", "", "")
    assert_equal(paths.config, "/home/test/.config/maki")
    assert_equal(paths.data, "/home/test/.local/share/maki")
    assert_equal(paths.state, "/home/test/.local/state/maki")
    assert_equal(paths.logs, "/home/test/.local/logs/maki")
    assert_equal(paths.cache, "/home/test/.cache/maki")

    var legacy = StoragePaths.from_roots(
        "/home/test", "/cfg", "/data", "/state", "/cache", True
    )
    assert_equal(legacy.config, "/home/test/.maki")
    assert_equal(legacy.data, "/home/test/.maki")
    assert_equal(legacy.state, "/home/test/.maki")
    assert_equal(legacy.logs, "/home/test/.maki")
    assert_equal(legacy.cache, "/home/test/.maki")
    assert_equal(legacy.xdg_config, "/cfg/maki")

    with assert_raises():
        _ = StoragePaths.from_roots("", "", "", "", "")


def test_maki_id_base58_and_legacy_uuid_round_trip() raises:
    var id = MakiId.parse(SAMPLE_UUID)
    var canonical = id.encode()
    assert_true(canonical.byte_length() >= 21)
    assert_true(canonical.byte_length() <= 22)
    assert_true(MakiId.parse(canonical) == id)
    assert_true(MakiId.parse("019650874c717f008000000000000000") == id)
    assert_equal(encode_base58(decode_base58(canonical)), canonical)
    var zero_bytes = List[UInt8]()
    for _ in range(16):
        zero_bytes.append(0)
    assert_equal(encode_base58(zero_bytes), "1111111111111111")
    assert_equal(len(decode_base58("1111111111111111")), 16)


def test_generated_maki_id_is_canonical_uuid_v7() raises:
    var generated = MakiId.generate()
    assert_equal(len(generated.bytes), 16)
    assert_equal(Int(generated.bytes[6] >> 4), 7)
    assert_equal(Int(generated.bytes[8] >> 6), 2)
    assert_true(MakiId.parse(generated.encode()) == generated)


def test_maki_id_rejects_invalid_values() raises:
    with assert_raises():
        _ = MakiId.parse("")
    with assert_raises():
        _ = MakiId.parse("O")
    with assert_raises():
        _ = MakiId.parse("2j87v4grC")


def test_session_ref_preserves_raw_spelling() raises:
    var reference = SessionRef(SAMPLE_UUID)
    assert_equal(reference.as_str(), SAMPLE_UUID)
    assert_true(reference.id == MakiId.parse(SAMPLE_UUID))
    var canonical = SessionRef.from_id(reference.id)
    assert_equal(canonical.as_str(), reference.id.encode())
    assert_false(canonical.as_str() == SAMPLE_UUID)


def test_oauth_tokens_upstream_json_codec() raises:
    var tokens = OAuthTokens("access", "refresh", 123456, Optional("acct"))
    var encoded = oauth_tokens_to_json(tokens)
    assert_equal(
        encoded,
        '{"access":"access","refresh":"refresh","expires":123456,"account_id":"acct"}',
    )
    var decoded = oauth_tokens_from_json(encoded)
    assert_equal(decoded.access, "access")
    assert_equal(decoded.refresh, "refresh")
    assert_equal(decoded.expires, 123456)
    assert_equal(decoded.account_id.value(), "acct")

    var without_account = oauth_tokens_from_json(
        '{"access":"a","refresh":"r","expires":9}'
    )
    assert_false(without_account.account_id)


def test_auth_record_upstream_json_codec() raises:
    var record = AuthRecord("secret", Optional("https://example.test"))
    assert_equal(
        auth_record_to_json(record),
        '{"api_key":"secret","host":"https://example.test"}',
    )
    var decoded = auth_record_from_json('{"api_key":"key"}')
    assert_equal(decoded.api_key, "key")
    assert_false(decoded.host)
    with assert_raises():
        _ = auth_record_from_json('{"host":"missing-key"}')


def test_mcp_auth_persistence_and_validation() raises:
    var paths = StoragePaths.from_roots(
        "/tmp/mochi-mcp-auth-home",
        "/tmp/mochi-mcp-auth-config",
        "/tmp/mochi-mcp-auth-data",
        "/tmp/mochi-mcp-auth-state",
        "/tmp/mochi-mcp-auth-cache",
    )
    delete_mcp_auth(paths, "server")
    var data = McpAuthData(
        "https://mcp.example/mcp",
        Optional(OAuthTokens("access", "refresh", 123456, None)),
        "client",
        Optional("secret"),
        Optional(2000),
        Optional("http://127.0.0.1:8765/callback"),
        Optional("https://auth.example/token"),
    )
    save_mcp_auth(paths, "server", data)
    assert_equal(
        mcp_auth_path(paths, "server"),
        "/tmp/mochi-mcp-auth-state/maki/auth/mcp-server.json",
    )
    var loaded = load_mcp_auth(
        paths, "server", "https://mcp.example/mcp", 1000
    )
    assert_true(loaded)
    assert_equal(loaded.value().tokens.value().access, "access")
    assert_equal(loaded.value().token_endpoint.value(), "https://auth.example/token")
    assert_false(load_mcp_auth(paths, "server", "https://other.example/mcp", 1000))
    assert_false(load_mcp_auth(paths, "server", "https://mcp.example/mcp", 2000))
    delete_mcp_auth(paths, "server")
    assert_false(load_mcp_auth(paths, "server", "https://mcp.example/mcp"))


def test_provider_credentials_persistence() raises:
    var paths = StoragePaths.from_roots(
        "/tmp/mochi-auth-home",
        "/tmp/mochi-auth-config",
        "/tmp/mochi-auth-data",
        "/tmp/mochi-auth-state",
        "/tmp/mochi-auth-cache",
    )
    delete_provider_credentials(paths, "copilot")
    assert_false(load_provider_credentials(paths, "copilot"))
    save_provider_credentials(
        paths, "copilot", AuthRecord("secret", Optional("github.com"))
    )
    assert_equal(
        provider_credentials_path(paths, "copilot"),
        "/tmp/mochi-auth-state/maki/auth/copilot.json",
    )
    var loaded = load_provider_credentials(paths, "copilot")
    assert_true(loaded)
    assert_equal(loaded.value().api_key, "secret")
    assert_equal(loaded.value().host.value(), "github.com")
    delete_provider_credentials(paths, "copilot")
    assert_false(load_provider_credentials(paths, "copilot"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
