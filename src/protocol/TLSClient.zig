// Derived from Zig 0.16.0 std.crypto.tls.Client (MIT); see
// /THIRD_PARTY_NOTICES.md. zc keeps this audited copy to separate SNI from
// identity verification and to
// respond correctly to TLS 1.3 KeyUpdate(update_requested).
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

const std = @import("std");
const tls = std.crypto.tls;
const Client = @This();
const mem = std.mem;
const crypto = std.crypto;
const assert = std.debug.assert;
const Certificate = std.crypto.Certificate;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const max_ciphertext_len = tls.max_ciphertext_len;
const hmacExpandLabel = tls.hmacExpandLabel;
const hkdfExpandLabel = tls.hkdfExpandLabel;
const int = tls.int;
const array = tls.array;
const tls_server_name = @import("tls_server_name.zig");

/// The encrypted stream from the server to the client. Bytes are pulled from
/// here via `reader`.
///
/// The buffer is asserted to have capacity at least `min_buffer_len`.
input: *Reader,
/// Holds authenticated plaintext until the caller consumes it.
reader: Reader,

/// The encrypted stream from the client to the server. Bytes are pushed here
/// via `writer`.
///
/// The buffer is asserted to have capacity at least `min_buffer_len`.
output: *Writer,
/// Buffers plaintext so records can be encrypted in bounded batches.
writer: Writer,

/// Stores the peer alert when record processing returns `error.TlsAlert`.
alert: ?tls.Alert = null,
read_error: ?ReadError = null,
write_error: ?WriteError = null,
tls_version: tls.ProtocolVersion,
read_sequence: u64,
write_sequence: u64,
/// When this is true, the stream may still not be at the end because there
/// may be data in the input buffer.
received_close_notify: bool,
received_user_canceled: bool = false,
application_cipher: tls.ApplicationCipher,
post_handshake: PostHandshakeState = .{},
last_record_event: RecordEvent = .need_more,
alert_parser: AlertParser = .{},

/// If non-null, SSL secrets are logged to a stream. Creating such a log file
/// allows other programs with access to that file to decrypt all traffic over
/// this connection.
ssl_key_log: ?*SSLKeyLog,

const PostHandshakeState = struct {
    kind: Kind = .header,
    header: [4]u8 = undefined,
    header_len: u3 = 0,
    remaining: u24 = 0,
    key_update_request: u8 = 0,

    const Kind = enum {
        header,
        new_session_ticket,
        key_update,
    };
};

const AlertParser = struct {
    pending_level: ?u8 = null,

    fn isIdle(parser: *const AlertParser) bool {
        return parser.pending_level == null;
    }

    fn next(
        parser: *AlertParser,
        input: []const u8,
        input_byte_index: *usize,
    ) ?tls.Alert {
        std.debug.assert(input_byte_index.* <= input.len);
        if (parser.pending_level) |level| {
            if (input_byte_index.* == input.len) return null;
            const description = input[input_byte_index.*];
            input_byte_index.* += 1;
            parser.pending_level = null;
            return .{
                .level = @enumFromInt(level),
                .description = @enumFromInt(description),
            };
        }
        if (input.len - input_byte_index.* < 2) {
            if (input_byte_index.* < input.len) {
                parser.pending_level = input[input_byte_index.*];
                input_byte_index.* += 1;
            }
            return null;
        }
        const alert: tls.Alert = .{
            .level = @enumFromInt(input[input_byte_index.*]),
            .description = @enumFromInt(input[input_byte_index.* + 1]),
        };
        input_byte_index.* += 2;
        return alert;
    }
};

pub const RecordEvent = enum {
    application_data,
    control,
    need_more,
    eof,
};

const AlertOutcome = enum {
    control,
    eof,
};

pub const WriteError = error{
    TLSSequenceOverflow,
};

const PreparedCiphertext = struct {
    ciphertext_output_byte_count: usize,
    plaintext_byte_count: usize,
    write_sequence_next: u64,
};

const DecryptedRecord = struct {
    plaintext_byte_count: usize,
    inner_content_type: tls.ContentType,
};

const DecryptRecordError = error{
    TlsBadRecordMac,
    TlsDecodeError,
    TlsRecordOverflow,
};

pub const ReadError = error{
    /// The alert description will be stored in `alert`.
    TlsAlert,
    TlsBadLength,
    TlsBadRecordMac,
    TLSConnectionTruncated,
    TlsDecodeError,
    TlsRecordOverflow,
    TlsUnexpectedMessage,
    TlsIllegalParameter,
    TlsKeyUpdateWriteFailed,
    TLSSequenceOverflow,
};

const KeyUpdateError = Writer.Error || error{TLSSequenceOverflow};

pub const SSLKeyLog = struct {
    client_key_sequence: u64,
    server_key_sequence: u64,
    client_random: [32]u8,
    writer: *Writer,

    fn clientCounter(
        key_log: *@This(),
    ) error{TLSSequenceOverflow}!u64 {
        const current = key_log.client_key_sequence;
        key_log.client_key_sequence = std.math.add(
            u64,
            current,
            1,
        ) catch return error.TLSSequenceOverflow;
        return current;
    }

    fn serverCounter(
        key_log: *@This(),
    ) error{TLSSequenceOverflow}!u64 {
        const current = key_log.server_key_sequence;
        key_log.server_key_sequence = std.math.add(
            u64,
            current,
            1,
        ) catch return error.TLSSequenceOverflow;
        return current;
    }
};

/// The `Reader` supplied to `init` requires a buffer capacity
/// at least this amount.
pub const min_buffer_len = tls.max_ciphertext_record_len;
const flush_iteration_count_max: u8 = 2;
const handshake_record_count_max: u16 = 256;
const handshake_message_count_max: u8 = 32;
const handshake_message_bytes_max: usize = 128 * 1024;
const ciphertext_record_count_max: u8 = 2;
const extension_count_max: u16 = @divExact(
    tls.max_ciphertext_inner_record_len,
    4,
);
const certificate_count_max: u16 = @divFloor(
    tls.max_ciphertext_inner_record_len,
    3,
);
const post_handshake_step_count_max: u16 =
    2 * tls.max_ciphertext_inner_record_len;
const signature_message_part_count_max: u8 = 4;
const writer_vector_count_max: u8 = 8;
const writer_splat_count_max: u8 = 8;
const alert_count_max: u16 = @divFloor(
    tls.max_ciphertext_inner_record_len,
    2,
) + 1;

comptime {
    assert(writer_vector_count_max > 0);
    assert(writer_splat_count_max > 0);
    assert(signature_message_part_count_max > 0);
    assert(@as(usize, alert_count_max) * 2 >=
        tls.max_ciphertext_inner_record_len + 1);
    assert(handshake_message_bytes_max >=
        2 * tls.max_ciphertext_inner_record_len);
    assert(min_buffer_len <=
        @as(usize, flush_iteration_count_max) *
            tls.max_ciphertext_inner_record_len);
}

const HandshakeFragments = struct {
    buffer: [handshake_message_bytes_max]u8 = undefined,
    consumed_offset: usize = 0,
    end_offset: usize = 0,
    writable_byte_count: usize = 0,

    const CapacityError = error{TlsRecordOverflow};

    fn append(fragments: *HandshakeFragments, bytes: []const u8) CapacityError!void {
        if (bytes.len == 0) return;
        const destination = try fragments.writable(bytes.len);
        @memcpy(destination, bytes);
        fragments.commit(bytes.len);
    }

    fn writable(
        fragments: *HandshakeFragments,
        byte_count: usize,
    ) CapacityError![]u8 {
        assert(fragments.writable_byte_count == 0);
        assert(fragments.consumed_offset <= fragments.end_offset);
        assert(fragments.end_offset <= fragments.buffer.len);
        const retained_byte_count = fragments.end_offset - fragments.consumed_offset;
        if (byte_count > fragments.buffer.len - retained_byte_count) {
            return error.TlsRecordOverflow;
        }
        if (byte_count > fragments.buffer.len - fragments.end_offset) {
            fragments.compact();
        }
        assert(byte_count <= fragments.buffer.len - fragments.end_offset);
        fragments.writable_byte_count = byte_count;
        return fragments.buffer[fragments.end_offset..][0..byte_count];
    }

    fn commit(fragments: *HandshakeFragments, byte_count: usize) void {
        assert(fragments.consumed_offset <= fragments.end_offset);
        assert(fragments.end_offset <= fragments.buffer.len);
        assert(byte_count <= fragments.writable_byte_count);
        assert(byte_count <= fragments.buffer.len - fragments.end_offset);
        fragments.end_offset += byte_count;
        fragments.writable_byte_count = 0;
    }

    fn decoder(fragments: *HandshakeFragments) tls.Decoder {
        assert(fragments.writable_byte_count == 0);
        assert(fragments.consumed_offset <= fragments.end_offset);
        assert(fragments.end_offset <= fragments.buffer.len);
        return .fromTheirSlice(
            fragments.buffer[fragments.consumed_offset..fragments.end_offset],
        );
    }

    fn advanceConsumed(fragments: *HandshakeFragments, byte_count: usize) void {
        assert(fragments.writable_byte_count == 0);
        assert(fragments.consumed_offset <= fragments.end_offset);
        assert(byte_count <= fragments.end_offset - fragments.consumed_offset);
        fragments.consumed_offset += byte_count;
    }

    fn reset(fragments: *HandshakeFragments) void {
        assert(fragments.writable_byte_count == 0);
        assert(fragments.consumed_offset == fragments.end_offset);
        fragments.consumed_offset = 0;
        fragments.end_offset = 0;
    }

    fn compact(fragments: *HandshakeFragments) void {
        assert(fragments.writable_byte_count == 0);
        assert(fragments.consumed_offset > 0);
        assert(fragments.consumed_offset <= fragments.end_offset);
        const retained_byte_count = fragments.end_offset - fragments.consumed_offset;
        // A single move bounds work even when records fragment a message adversarially.
        mem.copyForwards(
            u8,
            fragments.buffer[0..retained_byte_count],
            fragments.buffer[fragments.consumed_offset..fragments.end_offset],
        );
        fragments.consumed_offset = 0;
        fragments.end_offset = retained_byte_count;
    }
};

pub const Options = struct {
    /// Selects the reference identity used for server certificate verification.
    host: union(enum) {
        /// No host verification is performed, which prevents a trusted connection from
        /// being established.
        no_verification,
        /// Verify that the server certificate was issued for a given host.
        explicit: []const u8,
    },
    /// Carries optional TLS SNI independently from certificate verification.
    /// A null value intentionally omits the server_name extension.
    server_name: ?[]const u8 = null,
    /// Selects the trust source used to authenticate server certificates.
    ca: union(enum) {
        /// No CA verification is performed, which prevents a trusted connection from
        /// being established.
        no_verification,
        /// Verify that the server certificate is a valid self-signed certificate.
        /// This provides no authorization guarantees, as anyone can create a
        /// self-signed certificate.
        self_signed,
        /// Verify that the server certificate is authorized by a given CA bundle.
        bundle: struct {
            gpa: std.mem.Allocator,
            io: std.Io,
            lock: *std.Io.RwLock,
            bundle: *Certificate.Bundle,
        },
    },
    write_buffer: []u8,
    read_buffer: []u8,
    /// Supplies cryptographically secure entropy only for the duration of `init`.
    /// The initializer never captures this pointer.
    entropy: *const [entropy_len]u8,
    /// Current time according to the wall clock / calendar.
    realtime_now: std.Io.Timestamp,

    /// If non-null, SSL secrets are logged to this stream. Creating such a log file allows
    /// other programs with access to that file to decrypt all traffic over this connection.
    ///
    /// Only the `writer` field is observed during the handshake (`init`).
    /// After that, the other fields are populated.
    ssl_key_log: ?*SSLKeyLog = null,
    /// Receives the peer alert when `init` returns `error.TlsAlert`.
    alert: ?*tls.Alert = null,

    pub const entropy_len = 240;
};

pub const InitError = error{
    InsufficientEntropy,
    InvalidServerName,
    DiskQuota,
    LockViolation,
    NotOpenForWriting,
    /// The alert description will be stored in `alert`.
    TlsAlert,
    TlsUnexpectedMessage,
    TlsIllegalParameter,
    TLSSequenceOverflow,
    TlsHandshakeRecordLimitExceeded,
    TlsHandshakeMessageLimitExceeded,
    TlsDecryptFailure,
    TlsRecordOverflow,
    TlsBadRecordMac,
    CertificateFieldHasInvalidLength,
    CertificateHostMismatch,
    CertificatePublicKeyInvalid,
    CertificateExpired,
    CertificateFieldHasWrongDataType,
    CertificateIssuerMismatch,
    CertificateNotYetValid,
    CertificateSignatureAlgorithmMismatch,
    CertificateSignatureAlgorithmUnsupported,
    CertificateSignatureInvalid,
    CertificateSignatureInvalidLength,
    CertificateSignatureNamedCurveUnsupported,
    CertificateSignatureUnsupportedBitCount,
    TlsCertificateNotVerified,
    TlsBadSignatureScheme,
    TlsBadRSASignatureBitCount,
    InvalidEncoding,
    IdentityElement,
    SignatureVerificationFailed,
    TlsDecryptError,
    TLSConnectionTruncated,
    TlsDecodeError,
    UnsupportedCertificateVersion,
    CertificateTimeInvalid,
    CertificateHasUnrecognizedObjectId,
    CertificateHasInvalidBitString,
    MessageTooLong,
    NegativeIntoUnsigned,
    TargetTooSmall,
    BufferTooSmall,
    InvalidSignature,
    NotSquare,
    NonCanonical,
    WeakPublicKey,
} || std.Io.Writer.Error || std.Io.Reader.ShortError || std.Io.Cancelable;

const KeyShare = struct {
    ml_kem768_key_pair: crypto.kem.ml_kem.MLKem768.KeyPair,
    secp256r1_key_pair: crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair,
    secp384r1_key_pair: crypto.sign.ecdsa.EcdsaP384Sha384.KeyPair,
    x25519_key_pair: crypto.dh.X25519.KeyPair,
    shared_secret_buffer: [shared_secret_byte_count_max]u8,
    shared_secret_byte_count: std.math.IntFittingRange(0, shared_secret_byte_count_max),

    const shared_secret_byte_count_max = @max(
        crypto.dh.X25519.shared_length + crypto.kem.ml_kem.MLKem768.shared_length,
        crypto.ecc.P256.scalar.encoded_length,
        crypto.ecc.P384.scalar.encoded_length,
        crypto.dh.X25519.shared_length,
    );

    fn init(
        key_share: *KeyShare,
        seed: *const [176]u8,
    ) error{IdentityElement}!void {
        key_share.ml_kem768_key_pair = try .generateDeterministic(seed[0..64].*);
        key_share.secp256r1_key_pair = try .generateDeterministic(seed[64..96].*);
        key_share.secp384r1_key_pair = try .generateDeterministic(seed[96..144].*);
        key_share.x25519_key_pair = try .generateDeterministic(seed[144..176].*);
        key_share.shared_secret_buffer = undefined;
        key_share.shared_secret_byte_count = 0;
    }

    fn exchange(
        key_share: *KeyShare,
        named_group: tls.NamedGroup,
        server_public_key: []const u8,
    ) error{ TlsIllegalParameter, TlsDecryptFailure }!void {
        switch (named_group) {
            .x25519_ml_kem768 => {
                const ml_kem_ciphertext_len =
                    crypto.kem.ml_kem.MLKem768.ciphertext_length;
                const x25519_public_key_len = crypto.dh.X25519.public_length;
                const combined_public_key_len =
                    ml_kem_ciphertext_len + x25519_public_key_len;
                if (server_public_key.len != combined_public_key_len) {
                    return error.TlsIllegalParameter;
                }

                const ml_kem_shared_secret =
                    key_share.ml_kem768_key_pair.secret_key.decaps(
                        server_public_key[0..ml_kem_ciphertext_len],
                    ) catch return error.TlsDecryptFailure;
                const x25519_public_key_tail =
                    server_public_key[ml_kem_ciphertext_len..];
                const x25519_public_key =
                    x25519_public_key_tail[0..x25519_public_key_len].*;
                const x25519_shared_secret = crypto.dh.X25519.scalarmult(
                    key_share.x25519_key_pair.secret_key,
                    x25519_public_key,
                ) catch return error.TlsDecryptFailure;
                @memcpy(
                    key_share.shared_secret_buffer[0..ml_kem_shared_secret.len],
                    &ml_kem_shared_secret,
                );
                const combined_shared_secret_len =
                    ml_kem_shared_secret.len + x25519_shared_secret.len;
                const x25519_output_start = ml_kem_shared_secret.len;
                const x25519_output =
                    key_share.shared_secret_buffer[x25519_output_start..combined_shared_secret_len];
                @memcpy(x25519_output, &x25519_shared_secret);
                key_share.shared_secret_byte_count = combined_shared_secret_len;
            },
            .secp256r1 => {
                const PublicKey = crypto.sign.ecdsa.EcdsaP256Sha256.PublicKey;
                const public_key = PublicKey.fromSec1(
                    server_public_key,
                ) catch return error.TlsDecryptFailure;
                const shared_point = public_key.p.mulPublic(
                    key_share.secp256r1_key_pair.secret_key.bytes,
                    .big,
                ) catch return error.TlsDecryptFailure;
                const shared_secret = shared_point.affineCoordinates().x.toBytes(.big);
                @memcpy(key_share.shared_secret_buffer[0..shared_secret.len], &shared_secret);
                key_share.shared_secret_byte_count = shared_secret.len;
            },
            .secp384r1 => {
                const PublicKey = crypto.sign.ecdsa.EcdsaP384Sha384.PublicKey;
                const public_key = PublicKey.fromSec1(
                    server_public_key,
                ) catch return error.TlsDecryptFailure;
                const shared_point = public_key.p.mulPublic(
                    key_share.secp384r1_key_pair.secret_key.bytes,
                    .big,
                ) catch return error.TlsDecryptFailure;
                const shared_secret = shared_point.affineCoordinates().x.toBytes(.big);
                @memcpy(key_share.shared_secret_buffer[0..shared_secret.len], &shared_secret);
                key_share.shared_secret_byte_count = shared_secret.len;
            },
            .x25519 => {
                const public_key_len = crypto.dh.X25519.public_length;
                if (server_public_key.len != public_key_len) return error.TlsIllegalParameter;
                const public_key = server_public_key[0..public_key_len].*;
                const shared_secret = crypto.dh.X25519.scalarmult(
                    key_share.x25519_key_pair.secret_key,
                    public_key,
                ) catch return error.TlsDecryptFailure;
                @memcpy(key_share.shared_secret_buffer[0..shared_secret.len], &shared_secret);
                key_share.shared_secret_byte_count = shared_secret.len;
            },
            else => return error.TlsIllegalParameter,
        }
    }

    fn getSharedSecret(key_share: *const KeyShare) ?[]const u8 {
        if (key_share.shared_secret_byte_count == 0) return null;
        assert(
            key_share.shared_secret_byte_count <=
                KeyShare.shared_secret_byte_count_max,
        );
        return key_share.shared_secret_buffer[0..key_share.shared_secret_byte_count];
    }
};

fn SchemeRSA(comptime scheme: tls.SignatureScheme) type {
    return switch (scheme) {
        .rsa_pkcs1_sha256,
        .rsa_pkcs1_sha384,
        .rsa_pkcs1_sha512,
        .rsa_pkcs1_sha1,
        => Certificate.rsa.PKCS1v1_5Signature,
        .rsa_pss_rsae_sha256,
        .rsa_pss_rsae_sha384,
        .rsa_pss_rsae_sha512,
        .rsa_pss_pss_sha256,
        .rsa_pss_pss_sha384,
        .rsa_pss_pss_sha512,
        => Certificate.rsa.PSSSignature,
        else => @compileError("bad scheme"),
    };
}

fn SchemeEDDSA(comptime scheme: tls.SignatureScheme) type {
    return switch (scheme) {
        .ed25519 => crypto.sign.Ed25519,
        else => @compileError("bad scheme"),
    };
}

fn SchemeHash(comptime scheme: tls.SignatureScheme) type {
    return switch (scheme) {
        .rsa_pkcs1_sha256,
        .ecdsa_secp256r1_sha256,
        .rsa_pss_rsae_sha256,
        .rsa_pss_pss_sha256,
        => crypto.hash.sha2.Sha256,
        .rsa_pkcs1_sha384,
        .ecdsa_secp384r1_sha384,
        .rsa_pss_rsae_sha384,
        .rsa_pss_pss_sha384,
        => crypto.hash.sha2.Sha384,
        .rsa_pkcs1_sha512,
        .rsa_pss_rsae_sha512,
        .rsa_pss_pss_sha512,
        => crypto.hash.sha2.Sha512,
        .rsa_pkcs1_sha1,
        .ecdsa_sha1,
        => crypto.hash.Sha1,
        else => @compileError("bad scheme"),
    };
}

const TLS12Authentication = enum {
    rsa,
    ecdsa,
};

const CertificatePublicKey = struct {
    algorithm: Certificate.AlgorithmCategory,
    buffer: [600]u8,
    length: u16,

    const VerifyError = error{ TlsDecodeError, TlsBadSignatureScheme, InvalidEncoding } ||
        // ECDSA:
        crypto.errors.EncodingError ||
        crypto.errors.NotSquareError ||
        crypto.errors.NonCanonicalError ||
        crypto.sign.ecdsa.Ecdsa(
            crypto.ecc.P256,
            crypto.hash.sha2.Sha256,
        ).Signature.VerifyError ||
        // RSA:
        error{TlsBadRSASignatureBitCount} ||
        Certificate.rsa.PublicKey.ParseDerError ||
        Certificate.rsa.PublicKey.FromBytesError ||
        Certificate.rsa.PSSSignature.VerifyError ||
        Certificate.rsa.PKCS1v1_5Signature.VerifyError ||
        // EdDSA:
        SchemeEDDSA(.ed25519).Signature.VerifyError;

    const ECDSACurve = enum {
        p256,
        p384,
    };

    const ECDSAVerification = struct {
        public_key: []const u8,
        encoded_signature: []const u8,
        message_parts: []const []const u8,
    };

    fn init(
        certificate_public_key: *CertificatePublicKey,
        algorithm: Certificate.AlgorithmCategory,
        public_key: []const u8,
    ) error{CertificatePublicKeyInvalid}!void {
        if (public_key.len > certificate_public_key.buffer.len) {
            return error.CertificatePublicKeyInvalid;
        }
        certificate_public_key.algorithm = algorithm;
        @memcpy(certificate_public_key.buffer[0..public_key.len], public_key);
        certificate_public_key.length = @intCast(public_key.len);
    }

    fn matchesTLS12Authentication(
        certificate_public_key: *const CertificatePublicKey,
        authentication: TLS12Authentication,
    ) bool {
        return switch (authentication) {
            .rsa => switch (certificate_public_key.algorithm) {
                .rsaEncryption, .rsassa_pss => true,
                else => false,
            },
            .ecdsa => switch (certificate_public_key.algorithm) {
                .X9_62_id_ecPublicKey, .curveEd25519 => true,
                else => false,
            },
        };
    }

    fn updateVerifier(
        verifier: anytype,
        message_parts: []const []const u8,
    ) void {
        assert(message_parts.len <= signature_message_part_count_max);
        for (0..signature_message_part_count_max) |part_index| {
            if (part_index == message_parts.len) break;
            verifier.update(message_parts[part_index]);
        }
    }

    fn detectECDSACurve(public_key: []const u8) error{InvalidEncoding}!ECDSACurve {
        if (public_key.len == 0) return error.InvalidEncoding;
        return switch (public_key[0]) {
            0x02, 0x03 => switch (public_key.len) {
                33 => .p256,
                49 => .p384,
                else => error.InvalidEncoding,
            },
            0x04 => switch (public_key.len) {
                65 => .p256,
                97 => .p384,
                else => error.InvalidEncoding,
            },
            else => error.InvalidEncoding,
        };
    }

    fn verifyECDSA(
        comptime Curve: type,
        comptime Hash: type,
        options: ECDSAVerification,
    ) VerifyError!void {
        assert(options.message_parts.len <= signature_message_part_count_max);
        const ECDSA = crypto.sign.ecdsa.Ecdsa(Curve, Hash);
        const signature = try ECDSA.Signature.fromDer(
            options.encoded_signature,
        );
        const key = try ECDSA.PublicKey.fromSec1(options.public_key);
        var verifier = try signature.verifier(key);
        updateVerifier(&verifier, options.message_parts);
        try verifier.verify();
    }

    fn verifyECDSAForVersion(
        tls_version: tls.ProtocolVersion,
        scheme: tls.SignatureScheme,
        options: ECDSAVerification,
    ) VerifyError!void {
        const curve = try detectECDSACurve(options.public_key);
        if (tls_version == .tls_1_3) {
            const expected_curve: ECDSACurve = switch (scheme) {
                .ecdsa_secp256r1_sha256 => .p256,
                .ecdsa_secp384r1_sha384 => .p384,
                else => return error.TlsBadSignatureScheme,
            };
            if (curve != expected_curve) return error.TlsBadSignatureScheme;
        } else if (tls_version != .tls_1_2) {
            return error.TlsBadSignatureScheme;
        }

        // TLS 1.2 uses these wire values for the hash; the SEC1 key selects the curve.
        switch (scheme) {
            inline .ecdsa_secp256r1_sha256,
            .ecdsa_secp384r1_sha384,
            => |comptime_scheme| {
                const Hash = SchemeHash(comptime_scheme);
                switch (curve) {
                    .p256 => return verifyECDSA(
                        crypto.ecc.P256,
                        Hash,
                        options,
                    ),
                    .p384 => return verifyECDSA(
                        crypto.ecc.P384,
                        Hash,
                        options,
                    ),
                }
            },
            else => return error.TlsBadSignatureScheme,
        }
    }

    fn validateSignatureSchemeForVersion(
        tls_version: tls.ProtocolVersion,
        scheme: tls.SignatureScheme,
    ) error{TlsBadSignatureScheme}!void {
        if (tls_version != .tls_1_3) return;
        switch (scheme) {
            .rsa_pss_rsae_sha256,
            .rsa_pss_rsae_sha384,
            .rsa_pss_rsae_sha512,
            .rsa_pss_pss_sha256,
            .rsa_pss_pss_sha384,
            .rsa_pss_pss_sha512,
            .ecdsa_secp256r1_sha256,
            .ecdsa_secp384r1_sha384,
            .ed25519,
            => {},
            else => return error.TlsBadSignatureScheme,
        }
    }

    fn validateRSASignatureLength(
        encoded_signature: []const u8,
        modulus_byte_count: usize,
    ) error{InvalidEncoding}!void {
        if (encoded_signature.len != modulus_byte_count) {
            return error.InvalidEncoding;
        }
    }

    fn verifySignature(
        certificate_public_key: *const CertificatePublicKey,
        tls_version: tls.ProtocolVersion,
        signature_decoder: *tls.Decoder,
        message_parts: []const []const u8,
    ) VerifyError!void {
        assert(message_parts.len <= signature_message_part_count_max);
        const public_key = certificate_public_key.buffer[0..certificate_public_key.length];

        try signature_decoder.ensure(2 + 2);
        const scheme = signature_decoder.decode(tls.SignatureScheme);
        const signature_len = signature_decoder.decode(u16);
        try signature_decoder.ensure(signature_len);
        const encoded_signature = signature_decoder.slice(signature_len);
        try validateSignatureSchemeForVersion(tls_version, scheme);

        const expected_algorithm = @as(
            Certificate.AlgorithmCategory,
            switch (scheme) {
                .ecdsa_secp256r1_sha256,
                .ecdsa_secp384r1_sha384,
                => .X9_62_id_ecPublicKey,
                .rsa_pkcs1_sha256,
                .rsa_pkcs1_sha384,
                .rsa_pkcs1_sha512,
                .rsa_pss_rsae_sha256,
                .rsa_pss_rsae_sha384,
                .rsa_pss_rsae_sha512,
                .rsa_pkcs1_sha1,
                => .rsaEncryption,
                .rsa_pss_pss_sha256,
                .rsa_pss_pss_sha384,
                .rsa_pss_pss_sha512,
                => .rsassa_pss,
                .ed25519 => .curveEd25519,
                else => return error.TlsBadSignatureScheme,
            },
        );
        if (certificate_public_key.algorithm != expected_algorithm) {
            return error.TlsBadSignatureScheme;
        }

        switch (scheme) {
            .ecdsa_secp256r1_sha256,
            .ecdsa_secp384r1_sha384,
            => try verifyECDSAForVersion(
                tls_version,
                scheme,
                .{
                    .public_key = public_key,
                    .encoded_signature = encoded_signature,
                    .message_parts = message_parts,
                },
            ),
            inline .rsa_pkcs1_sha256,
            .rsa_pkcs1_sha384,
            .rsa_pkcs1_sha512,
            .rsa_pss_rsae_sha256,
            .rsa_pss_rsae_sha384,
            .rsa_pss_rsae_sha512,
            .rsa_pss_pss_sha256,
            .rsa_pss_pss_sha384,
            .rsa_pss_pss_sha512,
            .rsa_pkcs1_sha1,
            => |comptime_scheme| {
                const RSASignature = SchemeRSA(comptime_scheme);
                const Hash = SchemeHash(comptime_scheme);
                const PublicKey = Certificate.rsa.PublicKey;
                const components = try PublicKey.parseDer(public_key);
                const exponent = components.exponent;
                const modulus = components.modulus;
                switch (modulus.len) {
                    inline 128, 256, 384, 512 => |modulus_len| {
                        try validateRSASignatureLength(
                            encoded_signature,
                            modulus_len,
                        );
                        const key: PublicKey = try .fromBytes(exponent, modulus);
                        const signature = RSASignature.fromBytes(
                            modulus_len,
                            encoded_signature,
                        );
                        try RSASignature.concatVerify(
                            modulus_len,
                            signature,
                            message_parts,
                            key,
                            Hash,
                        );
                    },
                    else => return error.TlsBadRSASignatureBitCount,
                }
            },
            inline .ed25519 => |comptime_scheme| {
                const EDDSA = SchemeEDDSA(comptime_scheme);
                if (encoded_signature.len != EDDSA.Signature.encoded_length) {
                    return error.InvalidEncoding;
                }
                const signature = EDDSA.Signature.fromBytes(
                    encoded_signature[0..EDDSA.Signature.encoded_length].*,
                );
                if (public_key.len != EDDSA.PublicKey.encoded_length) return error.InvalidEncoding;
                const key = try EDDSA.PublicKey.fromBytes(
                    public_key[0..EDDSA.PublicKey.encoded_length].*,
                );
                var verifier = try signature.verifier(key);
                updateVerifier(&verifier, message_parts);
                try verifier.verify();
            },
            else => unreachable,
        }
    }
};

fn validateCompressionMethod(
    compression_method: tls.CompressionMethod,
) error{TlsIllegalParameter}!void {
    if (compression_method != .null) return error.TlsIllegalParameter;
}

fn initializeTLS13HandshakeSecrets(
    cipher: anytype,
    shared_secret: []const u8,
    ssl_key_log: ?*SSLKeyLog,
    client_hello_random: *const [32]u8,
) Writer.Error!void {
    assert(shared_secret.len > 0);
    assert(shared_secret.len <= KeyShare.shared_secret_byte_count_max);
    const Cipher = @TypeOf(cipher.*).A;
    const hello_hash = cipher.transcript_hash.peek();
    const zeroes = [1]u8{0} ** Cipher.Hash.digest_length;
    const early_secret = Cipher.Hkdf.extract(&[1]u8{0}, &zeroes);
    const empty_hash = tls.emptyHash(Cipher.Hash);
    cipher.version = .{ .tls_1_3 = undefined };
    const state = &cipher.version.tls_1_3;
    const handshake_derived_secret = hkdfExpandLabel(
        Cipher.Hkdf,
        early_secret,
        "derived",
        &empty_hash,
        Cipher.Hash.digest_length,
    );
    state.handshake_secret = Cipher.Hkdf.extract(
        &handshake_derived_secret,
        shared_secret,
    );
    const application_derived_secret = hkdfExpandLabel(
        Cipher.Hkdf,
        state.handshake_secret,
        "derived",
        &empty_hash,
        Cipher.Hash.digest_length,
    );
    state.master_secret = Cipher.Hkdf.extract(
        &application_derived_secret,
        &zeroes,
    );
    const client_secret = hkdfExpandLabel(
        Cipher.Hkdf,
        state.handshake_secret,
        "c hs traffic",
        &hello_hash,
        Cipher.Hash.digest_length,
    );
    const server_secret = hkdfExpandLabel(
        Cipher.Hkdf,
        state.handshake_secret,
        "s hs traffic",
        &hello_hash,
        Cipher.Hash.digest_length,
    );
    if (ssl_key_log) |key_log| {
        try logSecrets(
            key_log.writer,
            .{ .client_random = client_hello_random },
            .{
                .SERVER_HANDSHAKE_TRAFFIC_SECRET = &server_secret,
                .CLIENT_HANDSHAKE_TRAFFIC_SECRET = &client_secret,
            },
        );
    }
    state.client_finished_key = hkdfExpandLabel(
        Cipher.Hkdf,
        client_secret,
        "finished",
        "",
        Cipher.Hmac.key_length,
    );
    state.server_finished_key = hkdfExpandLabel(
        Cipher.Hkdf,
        server_secret,
        "finished",
        "",
        Cipher.Hmac.key_length,
    );
    state.client_handshake_key = hkdfExpandLabel(
        Cipher.Hkdf,
        client_secret,
        "key",
        "",
        Cipher.AEAD.key_length,
    );
    state.server_handshake_key = hkdfExpandLabel(
        Cipher.Hkdf,
        server_secret,
        "key",
        "",
        Cipher.AEAD.key_length,
    );
    state.client_handshake_iv = hkdfExpandLabel(
        Cipher.Hkdf,
        client_secret,
        "iv",
        "",
        Cipher.AEAD.nonce_length,
    );
    state.server_handshake_iv = hkdfExpandLabel(
        Cipher.Hkdf,
        server_secret,
        "iv",
        "",
        Cipher.AEAD.nonce_length,
    );
}

/// Initiates a TLS handshake and establishes a TLSv1.2 or TLSv1.3 session.
///
/// `host` and `server_name` are only borrowed during this function call.
///
/// `input` is asserted to have buffer capacity at least `min_buffer_len`.
pub fn init(
    target: *Client,
    input: *Reader,
    output: *Writer,
    options: Options,
) InitError!void {
    assert(input.buffer.len >= min_buffer_len);
    assert(options.read_buffer.len >= min_buffer_len);
    assert(options.write_buffer.len == min_buffer_len);
    const verify_host = switch (options.host) {
        .no_verification => "",
        .explicit => |host| host,
    };
    const server_name = options.server_name orelse "";
    if (options.server_name != null) {
        tls_server_name.validateSNI(server_name) catch {
            return error.InvalidServerName;
        };
    }
    const server_name_byte_count: u16 = @intCast(server_name.len);

    const client_hello_random = options.entropy[0..32].*;
    var key_sequence: u64 = 0;
    var server_hello_random: [32]u8 = undefined;
    const legacy_session_id = options.entropy[32..64].*;

    var key_share: KeyShare = undefined;
    defer crypto.secureZero(u8, mem.asBytes(&key_share));
    KeyShare.init(&key_share, options.entropy[64..240]) catch |err| switch (err) {
        // Only an all-zero seed can produce the identity element.
        error.IdentityElement => return error.InsufficientEntropy,
    };

    const extensions_payload = tls.extension(.supported_versions, array(u8, tls.ProtocolVersion, .{
        .tls_1_3,
        .tls_1_2,
    })) ++ tls.extension(.signature_algorithms, array(u16, tls.SignatureScheme, .{
        .ecdsa_secp256r1_sha256,
        .ecdsa_secp384r1_sha384,
        .rsa_pkcs1_sha256,
        .rsa_pkcs1_sha384,
        .rsa_pkcs1_sha512,
        .rsa_pss_rsae_sha256,
        .rsa_pss_rsae_sha384,
        .rsa_pss_rsae_sha512,
        .rsa_pss_pss_sha256,
        .rsa_pss_pss_sha384,
        .rsa_pss_pss_sha512,
        .rsa_pkcs1_sha1,
        .ed25519,
    })) ++ tls.extension(.supported_groups, array(u16, tls.NamedGroup, .{
        .x25519_ml_kem768,
        .secp256r1,
        .secp384r1,
        .x25519,
    })) ++ tls.extension(.psk_key_exchange_modes, array(u8, tls.PskKeyExchangeMode, .{
        .psk_dhe_ke,
    })) ++ tls.extension(.key_share, array(
        u16,
        u8,
        int(u16, @intFromEnum(tls.NamedGroup.x25519_ml_kem768)) ++
            array(
                u16,
                u8,
                key_share.ml_kem768_key_pair.public_key.toBytes() ++
                    key_share.x25519_key_pair.public_key,
            ) ++
            int(u16, @intFromEnum(tls.NamedGroup.secp256r1)) ++
            array(u16, u8, key_share.secp256r1_key_pair.public_key.toUncompressedSec1()) ++
            int(u16, @intFromEnum(tls.NamedGroup.secp384r1)) ++
            array(u16, u8, key_share.secp384r1_key_pair.public_key.toUncompressedSec1()) ++
            int(u16, @intFromEnum(tls.NamedGroup.x25519)) ++
            array(u16, u8, key_share.x25519_key_pair.public_key),
    ));
    const server_name_extension = int(u16, @intFromEnum(tls.ExtensionType.server_name)) ++
        int(u16, 2 + 1 + 2 + server_name_byte_count) ++ // byte length of this extension payload
        int(u16, 1 + 2 + server_name_byte_count) ++ // server_name_list byte count
        .{0x00} ++ // name_type
        int(u16, server_name_byte_count);
    const server_name_extension_len = if (options.server_name == null)
        0
    else
        server_name_extension.len + server_name.len;

    const extensions_header =
        int(u16, @intCast(extensions_payload.len + server_name_extension_len)) ++
        extensions_payload ++
        server_name_extension;

    const client_hello =
        int(u16, @intFromEnum(tls.ProtocolVersion.tls_1_2)) ++
        client_hello_random ++
        [1]u8{32} ++ legacy_session_id ++
        cipher_suites ++
        array(u8, tls.CompressionMethod, .{.null}) ++
        extensions_header;

    const out_handshake = .{@intFromEnum(tls.HandshakeType.client_hello)} ++
        int(
            u24,
            @intCast(
                client_hello.len -
                    server_name_extension.len +
                    server_name_extension_len,
            ),
        ) ++
        client_hello;

    const cleartext_header_buf = .{@intFromEnum(tls.ContentType.handshake)} ++
        int(u16, @intFromEnum(tls.ProtocolVersion.tls_1_0)) ++
        int(
            u16,
            @intCast(
                out_handshake.len -
                    server_name_extension.len +
                    server_name_extension_len,
            ),
        ) ++
        out_handshake;
    const cleartext_header = if (options.server_name == null)
        cleartext_header_buf[0 .. cleartext_header_buf.len - server_name_extension.len]
    else
        &cleartext_header_buf;

    {
        var iovecs: [2][]const u8 = .{ cleartext_header, server_name };
        try output.writeVecAll(iovecs[0..if (server_name.len == 0) 1 else 2]);
        try output.flush();
    }

    var tls_version: tls.ProtocolVersion = undefined;
    var chain: Certificate.Chain = if (Certificate.Chain != void) .empty;
    defer if (Certificate.Chain != void) chain.deinit();
    // The first certificate carries the identity that must match the requested host.
    var certificate_index: u16 = 0;
    var write_sequence: u64 = 0;
    var read_sequence: u64 = 0;
    var previous_certificate: Certificate.Parsed = undefined;
    const CipherState = enum {
        /// No cipher is in use.
        cleartext,
        /// Handshake cipher is in use.
        handshake,
        /// Application cipher is in use.
        application,
    };
    var pending_cipher_state: CipherState = .cleartext;
    var cipher_state = pending_cipher_state;
    const HandshakeState = enum {
        /// In this state we expect only a server hello message.
        hello,
        /// In this state we expect only an encrypted_extensions message.
        encrypted_extensions,
        /// In this state we expect certificate handshake messages.
        certificate,
        /// In this state we expect certificate or certificate_verify messages.
        /// Once trust is established, additional certificate messages are ignored.
        trust_chain_established,
        /// In this state, we expect only the server_hello_done handshake message.
        server_hello_done,
        /// In this state, we expect only the finished handshake message.
        finished,
    };
    var handshake_state: HandshakeState = .hello;
    var handshake_cipher: tls.HandshakeCipher = undefined;
    var main_certificate_public_key: CertificatePublicKey = undefined;
    var tls_1_2_negotiated_group: ?tls.NamedGroup = null;
    var tls_1_2_authentication: ?TLS12Authentication = null;
    const current_time_seconds = options.realtime_now.toSeconds();

    var handshake_fragments: HandshakeFragments = .{};
    var handshake_alert_parser: AlertParser = .{};
    var provisional_compatibility_ccs_received = false;
    var handshake_message_count: u8 = 0;
    fragment: for (0..handshake_record_count_max) |_| {
        // Ensure the input buffer pointer is stable in this scope.
        input.rebase(tls.max_ciphertext_record_len) catch |err| switch (err) {
            error.EndOfStream => {}, // We have assurance the remainder of stream can be buffered.
            error.ReadFailed => |e| return e,
        };
        const record_header = input.peek(tls.record_header_len) catch |err| switch (err) {
            error.EndOfStream => return error.TLSConnectionTruncated,
            error.ReadFailed => |e| return e,
        };
        // The preceding peek guarantees success.
        const record_content_type = input.takeEnumNonexhaustive(
            tls.ContentType,
            .big,
        ) catch unreachable;
        input.toss(2); // legacy_version
        // The preceding peek guarantees this length decode succeeds.
        const record_byte_count = input.takeInt(u16, .big) catch unreachable;
        if (record_byte_count > tls.max_ciphertext_len) {
            return error.TlsRecordOverflow;
        }
        if (cipher_state == .cleartext) {
            if (record_byte_count > tls.max_ciphertext_inner_record_len) {
                return error.TlsRecordOverflow;
            }
        }
        const record_buffer = input.take(record_byte_count) catch |err| switch (err) {
            error.EndOfStream => return error.TLSConnectionTruncated,
            error.ReadFailed => return error.ReadFailed,
        };
        var record_decoder: tls.Decoder = .fromTheirSlice(record_buffer);
        if (record_content_type == .change_cipher_spec) {
            try consumeCompatibilityChangeCipherSpec(
                &record_decoder,
                record_byte_count,
            );
            if (handshake_state == .hello) {
                provisional_compatibility_ccs_received = true;
                continue :fragment;
            }
            if (tls_version == .tls_1_3) continue :fragment;
            if (tls_version != .tls_1_2) {
                return error.TlsUnexpectedMessage;
            }
            if (cipher_state != .cleartext) {
                return error.TlsUnexpectedMessage;
            }
            if (pending_cipher_state != .application) {
                return error.TlsUnexpectedMessage;
            }
            cipher_state = .application;
            continue :fragment;
        }
        if (cipher_state == .handshake) {
            if (tls_version != .tls_1_3) {
                return error.TlsUnexpectedMessage;
            }
        }
        var content_decoder, const content_type = content: switch (cipher_state) {
            .cleartext => {
                if (record_content_type == .handshake) {
                    try handshake_fragments.append(record_buffer);
                    break :content .{ handshake_fragments.decoder(), record_content_type };
                }
                // Control records cannot contribute bytes to a fragmented handshake message.
                break :content .{ record_decoder, record_content_type };
            },
            .handshake => {
                assert(tls_version == .tls_1_3);
                if (record_content_type != .application_data) {
                    return error.TlsUnexpectedMessage;
                }
                try record_decoder.ensure(record_byte_count);
                var decrypted_content: []const u8 = undefined;
                switch (handshake_cipher) {
                    inline else => |*cipher| {
                        const state = &cipher.version.tls_1_3;
                        const Cipher = @TypeOf(cipher.*).A;
                        if (record_byte_count < Cipher.AEAD.tag_length + 1) {
                            return error.TlsDecodeError;
                        }
                        const ciphertext = record_decoder.slice(
                            record_byte_count - Cipher.AEAD.tag_length,
                        );
                        const cleartext = try handshake_fragments.writable(ciphertext.len);
                        const auth_tag = record_decoder.array(Cipher.AEAD.tag_length).*;
                        const nonce = nonce: {
                            const NonceVector = @Vector(Cipher.AEAD.nonce_length, u8);
                            const pad = [1]u8{0} ** (Cipher.AEAD.nonce_length - 8);
                            const operand: NonceVector = pad ++
                                @as([8]u8, @bitCast(big(read_sequence)));
                            break :nonce @as(NonceVector, state.server_handshake_iv) ^ operand;
                        };
                        Cipher.AEAD.decrypt(
                            cleartext,
                            ciphertext,
                            auth_tag,
                            record_header,
                            nonce,
                            state.server_handshake_key,
                        ) catch return error.TlsBadRecordMac;
                        // TLS padding is excluded so only protocol content can be accumulated.
                        decrypted_content = mem.trimEnd(u8, cleartext, "\x00");
                        if (decrypted_content.len == 0) return error.TlsDecodeError;
                    },
                }
                read_sequence = std.math.add(u64, read_sequence, 1) catch
                    return error.TLSSequenceOverflow;
                const content_byte_count = decrypted_content.len - 1;
                if (content_byte_count > tls.max_ciphertext_inner_record_len) {
                    return error.TlsRecordOverflow;
                }
                const decrypted_content_type: tls.ContentType = @enumFromInt(
                    decrypted_content[content_byte_count],
                );
                if (decrypted_content_type == .handshake) {
                    handshake_fragments.commit(content_byte_count);
                    break :content .{
                        handshake_fragments.decoder(),
                        decrypted_content_type,
                    };
                }
                handshake_fragments.commit(0);
                break :content .{
                    tls.Decoder.fromTheirSlice(
                        @constCast(decrypted_content[0..content_byte_count]),
                    ),
                    decrypted_content_type,
                };
            },
            .application => {
                assert(tls_version == .tls_1_2);
                try record_decoder.ensure(record_byte_count);
                var cleartext: []u8 = undefined;
                var message_byte_count: u16 = undefined;
                switch (handshake_cipher) {
                    inline else => |*cipher| {
                        const state = &cipher.version.tls_1_2;
                        const Cipher = @TypeOf(cipher.*).A;
                        if (record_byte_count < Cipher.record_iv_length + Cipher.mac_length) {
                            return error.TlsRecordOverflow;
                        }
                        message_byte_count =
                            record_byte_count - Cipher.record_iv_length - Cipher.mac_length;
                        if (message_byte_count >
                            tls.max_ciphertext_inner_record_len)
                        {
                            return error.TlsRecordOverflow;
                        }
                        cleartext = try handshake_fragments.writable(message_byte_count);
                        const additional_data = mem.toBytes(big(read_sequence)) ++
                            record_header[0 .. 1 + 2] ++
                            mem.toBytes(big(message_byte_count));
                        const record_iv = record_decoder.array(Cipher.record_iv_length).*;
                        const masked_read_sequence = read_sequence &
                            comptime std.math.shl(
                                u64,
                                std.math.maxInt(u64),
                                8 * Cipher.record_iv_length,
                            );
                        const nonce: [Cipher.AEAD.nonce_length]u8 = nonce: {
                            const NonceVector = @Vector(Cipher.AEAD.nonce_length, u8);
                            const pad = [1]u8{0} ** (Cipher.AEAD.nonce_length - 8);
                            const operand: NonceVector = pad ++
                                @as([8]u8, @bitCast(big(masked_read_sequence)));
                            const nonce_base = @as(
                                NonceVector,
                                state.app_cipher.server_write_IV ++ record_iv,
                            );
                            break :nonce nonce_base ^ operand;
                        };
                        const ciphertext = record_decoder.slice(message_byte_count);
                        const auth_tag = record_decoder.array(Cipher.mac_length);
                        Cipher.AEAD.decrypt(
                            cleartext,
                            ciphertext,
                            auth_tag.*,
                            additional_data,
                            nonce,
                            state.app_cipher.server_write_key,
                        ) catch return error.TlsBadRecordMac;
                    },
                }
                read_sequence = std.math.add(u64, read_sequence, 1) catch
                    return error.TLSSequenceOverflow;
                if (record_content_type == .handshake) {
                    handshake_fragments.commit(message_byte_count);
                    break :content .{
                        handshake_fragments.decoder(),
                        record_content_type,
                    };
                }
                handshake_fragments.commit(0);
                break :content .{
                    tls.Decoder.fromTheirSlice(cleartext),
                    record_content_type,
                };
            },
        };
        if (!handshake_alert_parser.isIdle()) {
            if (content_type != .alert) return error.TlsUnexpectedMessage;
        }
        switch (content_type) {
            .alert => {
                const alert = alert: {
                    if (cipher_state == .handshake) {
                        if (content_decoder.rest().len != 2) {
                            return error.TlsDecodeError;
                        }
                        try content_decoder.ensure(2);
                        break :alert tls.Alert{
                            .level = content_decoder.decode(tls.Alert.Level),
                            .description = content_decoder.decode(
                                tls.Alert.Description,
                            ),
                        };
                    }
                    var alert_byte_index: usize = 0;
                    break :alert handshake_alert_parser.next(
                        content_decoder.rest(),
                        &alert_byte_index,
                    ) orelse continue :fragment;
                };
                if (options.alert) |output_alert| output_alert.* = alert;
                return error.TlsAlert;
            },
            .change_cipher_spec => return error.TlsUnexpectedMessage,
            .handshake => {
                for (0..handshake_message_count_max) |_| {
                    content_decoder.ensure(4) catch continue :fragment;
                    const handshake_type = content_decoder.decode(tls.HandshakeType);
                    const handshake_len = content_decoder.decode(u24);
                    var handshake_decoder = content_decoder.sub(
                        handshake_len,
                    ) catch continue :fragment;
                    if (handshake_message_count == handshake_message_count_max) {
                        return error.TlsHandshakeMessageLimitExceeded;
                    }
                    handshake_message_count += 1;
                    const handshake_start = content_decoder.idx - handshake_len - 4;
                    const handshake_end = content_decoder.idx;
                    const wrapped_handshake = content_decoder.buf[handshake_start..handshake_end];
                    switch (handshake_type) {
                        .server_hello => {
                            if (cipher_state != .cleartext) return error.TlsUnexpectedMessage;
                            if (handshake_state != .hello) return error.TlsUnexpectedMessage;
                            try handshake_decoder.ensure(2 + 32 + 1);
                            const legacy_version = handshake_decoder.decode(u16);
                            @memcpy(&server_hello_random, handshake_decoder.array(32));
                            if (mem.eql(
                                u8,
                                &server_hello_random,
                                &tls.hello_retry_request_sequence,
                            )) {
                                // This is a HelloRetryRequest message. This client implementation
                                // does not expect to get one.
                                return error.TlsUnexpectedMessage;
                            }
                            const legacy_session_id_echo_byte_count = handshake_decoder.decode(u8);
                            try handshake_decoder.ensure(legacy_session_id_echo_byte_count + 2 + 1);
                            const legacy_session_id_echo = handshake_decoder.slice(
                                legacy_session_id_echo_byte_count,
                            );
                            const cipher_suite_tag = handshake_decoder.decode(
                                tls.CipherSuite,
                            );
                            const compression_method = handshake_decoder.decode(
                                tls.CompressionMethod,
                            );
                            try validateCompressionMethod(compression_method);
                            var supported_version: ?u16 = null;
                            if (!handshake_decoder.eof()) {
                                try handshake_decoder.ensure(2);
                                const extensions_byte_count = handshake_decoder.decode(u16);
                                var extensions_decoder = try handshake_decoder.sub(
                                    extensions_byte_count,
                                );
                                for (0..extension_count_max) |_| {
                                    if (extensions_decoder.eof()) break;
                                    try extensions_decoder.ensure(2 + 2);
                                    const extension_type = extensions_decoder.decode(
                                        tls.ExtensionType,
                                    );
                                    const extension_byte_count = extensions_decoder.decode(u16);
                                    var extension_decoder = try extensions_decoder.sub(
                                        extension_byte_count,
                                    );
                                    switch (extension_type) {
                                        .supported_versions => {
                                            if (supported_version) |_| {
                                                return error.TlsIllegalParameter;
                                            }
                                            try extension_decoder.ensure(2);
                                            supported_version = extension_decoder.decode(u16);
                                        },
                                        .key_share => {
                                            if (key_share.getSharedSecret()) |_| {
                                                return error.TlsIllegalParameter;
                                            }
                                            try extension_decoder.ensure(4);
                                            const named_group = extension_decoder.decode(
                                                tls.NamedGroup,
                                            );
                                            const key_byte_count = extension_decoder.decode(u16);
                                            try extension_decoder.ensure(key_byte_count);
                                            try key_share.exchange(
                                                named_group,
                                                extension_decoder.slice(key_byte_count),
                                            );
                                        },
                                        else => {},
                                    }
                                }
                                if (!extensions_decoder.eof()) {
                                    return error.TlsRecordOverflow;
                                }
                            }
                            if (!handshake_decoder.eof()) {
                                return error.TlsIllegalParameter;
                            }

                            tls_version = @enumFromInt(supported_version orelse legacy_version);
                            switch (tls_version) {
                                .tls_1_3 => {
                                    if (!mem.eql(
                                        u8,
                                        legacy_session_id_echo,
                                        &legacy_session_id,
                                    )) {
                                        return error.TlsIllegalParameter;
                                    }
                                },
                                .tls_1_2 => {
                                    if (provisional_compatibility_ccs_received) {
                                        return error.TlsUnexpectedMessage;
                                    }
                                    const has_downgrade_marker = mem.eql(
                                        u8,
                                        server_hello_random[24..31],
                                        "DOWNGRD",
                                    );
                                    if (has_downgrade_marker) {
                                        if (server_hello_random[31] >> 1 == 0x00) {
                                            return error.TlsIllegalParameter;
                                        }
                                    }
                                },
                                else => return error.TlsIllegalParameter,
                            }

                            switch (cipher_suite_tag) {
                                inline .AES_128_GCM_SHA256,
                                .AES_256_GCM_SHA384,
                                .CHACHA20_POLY1305_SHA256,
                                .AEGIS_256_SHA512,
                                .AEGIS_128L_SHA256,

                                .ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                                .ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
                                .ECDHE_RSA_WITH_AES_256_GCM_SHA384,
                                .ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
                                .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
                                .ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
                                => |tag| {
                                    handshake_cipher = @unionInit(
                                        tls.HandshakeCipher,
                                        @tagName(tag.with()),
                                        .{
                                            .transcript_hash = .init(.{}),
                                            .version = undefined,
                                        },
                                    );
                                    const cipher = &@field(
                                        handshake_cipher,
                                        @tagName(tag.with()),
                                    );
                                    // Hash the fixed ClientHello bytes before
                                    // the optional SNI bytes.
                                    cipher.transcript_hash.update(
                                        cleartext_header[tls.record_header_len..],
                                    );
                                    // Hash the optional SNI bytes after the
                                    // fixed ClientHello bytes.
                                    cipher.transcript_hash.update(server_name);
                                    cipher.transcript_hash.update(wrapped_handshake);
                                },

                                else => return error.TlsIllegalParameter,
                            }
                            switch (tls_version) {
                                .tls_1_3 => {
                                    switch (cipher_suite_tag) {
                                        inline .AES_128_GCM_SHA256,
                                        .AES_256_GCM_SHA384,
                                        .CHACHA20_POLY1305_SHA256,
                                        .AEGIS_256_SHA512,
                                        .AEGIS_128L_SHA256,
                                        => |tag| {
                                            const shared_secret_optional =
                                                key_share.getSharedSecret();
                                            const shared_secret = shared_secret_optional orelse {
                                                return error.TlsIllegalParameter;
                                            };
                                            const cipher = &@field(
                                                handshake_cipher,
                                                @tagName(tag.with()),
                                            );
                                            try initializeTLS13HandshakeSecrets(
                                                cipher,
                                                shared_secret,
                                                options.ssl_key_log,
                                                &client_hello_random,
                                            );
                                        },
                                        else => return error.TlsIllegalParameter,
                                    }
                                    pending_cipher_state = .handshake;
                                    cipher_state = .handshake;
                                    handshake_state = .encrypted_extensions;
                                },
                                .tls_1_2 => {
                                    tls_1_2_authentication = switch (cipher_suite_tag) {
                                        .ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                                        .ECDHE_RSA_WITH_AES_256_GCM_SHA384,
                                        .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
                                        => .rsa,
                                        .ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
                                        .ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
                                        .ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
                                        => .ecdsa,
                                        else => return error.TlsIllegalParameter,
                                    };
                                    handshake_state = .certificate;
                                },
                                else => return error.TlsIllegalParameter,
                            }
                        },
                        .encrypted_extensions => {
                            if (tls_version != .tls_1_3) return error.TlsUnexpectedMessage;
                            if (cipher_state != .handshake) return error.TlsUnexpectedMessage;
                            if (handshake_state != .encrypted_extensions) {
                                return error.TlsUnexpectedMessage;
                            }
                            switch (handshake_cipher) {
                                inline else => |*cipher| {
                                    cipher.transcript_hash.update(wrapped_handshake);
                                },
                            }
                            try handshake_decoder.ensure(2);
                            const total_extension_byte_count = handshake_decoder.decode(u16);
                            var extensions_decoder = try handshake_decoder.sub(
                                total_extension_byte_count,
                            );
                            var seen_server_name = false;
                            for (0..extension_count_max) |_| {
                                if (extensions_decoder.eof()) break;
                                try extensions_decoder.ensure(4);
                                const extension_type = extensions_decoder.decode(tls.ExtensionType);
                                const extension_byte_count = extensions_decoder.decode(u16);
                                const extension_decoder = try extensions_decoder.sub(
                                    extension_byte_count,
                                );
                                switch (extension_type) {
                                    .server_name => {
                                        if (options.server_name == null) {
                                            return error.TlsIllegalParameter;
                                        }
                                        if (seen_server_name) {
                                            return error.TlsIllegalParameter;
                                        }
                                        if (!extension_decoder.eof()) {
                                            return error.TlsIllegalParameter;
                                        }
                                        seen_server_name = true;
                                    },
                                    else => {},
                                }
                            }
                            if (!extensions_decoder.eof()) {
                                return error.TlsRecordOverflow;
                            }
                            handshake_state = .certificate;
                        },
                        .certificate => cert: {
                            if (cipher_state == .application) return error.TlsUnexpectedMessage;
                            switch (handshake_state) {
                                .certificate => {},
                                .trust_chain_established => break :cert,
                                else => return error.TlsUnexpectedMessage,
                            }
                            switch (handshake_cipher) {
                                inline else => |*cipher| {
                                    cipher.transcript_hash.update(wrapped_handshake);
                                },
                            }

                            switch (tls_version) {
                                .tls_1_3 => {
                                    try handshake_decoder.ensure(1 + 3);
                                    const certificate_request_context_byte_count =
                                        handshake_decoder.decode(u8);
                                    if (certificate_request_context_byte_count != 0) {
                                        return error.TlsIllegalParameter;
                                    }
                                },
                                .tls_1_2 => try handshake_decoder.ensure(3),
                                else => unreachable,
                            }
                            const certificates_byte_count = handshake_decoder.decode(u24);
                            const certs = try handshake_decoder.sub(certificates_byte_count);

                            var certificates_decoder = certs;
                            for (0..certificate_count_max) |_| {
                                if (certificates_decoder.eof()) break;
                                try certificates_decoder.ensure(3);
                                const certificate_byte_count = certificates_decoder.decode(u24);
                                const certificate_decoder = try certificates_decoder.sub(
                                    certificate_byte_count,
                                );

                                if (tls_version == .tls_1_3) {
                                    try certificates_decoder.ensure(2);
                                    const total_extension_byte_count =
                                        certificates_decoder.decode(u16);
                                    const extensions_decoder = try certificates_decoder.sub(
                                        total_extension_byte_count,
                                    );
                                    _ = extensions_decoder;
                                }

                                const subject_cert: Certificate = .{
                                    .buffer = certificate_decoder.buf,
                                    .index = @intCast(certificate_decoder.idx),
                                };
                                const subject = try subject_cert.parse();
                                if (certificate_index == 0) {
                                    // Verify the host on the first certificate.
                                    switch (options.host) {
                                        .no_verification => {},
                                        .explicit => try subject.verifyHostName(verify_host),
                                    }

                                    // Keep track of the public key for the
                                    // certificate_verify message later.
                                    try main_certificate_public_key.init(
                                        subject.pub_key_algo,
                                        subject.pubKey(),
                                    );
                                } else {
                                    try previous_certificate.verify(subject, current_time_seconds);
                                }

                                switch (options.ca) {
                                    .no_verification => {
                                        handshake_state = .trust_chain_established;
                                        break :cert;
                                    },
                                    .self_signed => {
                                        try subject.verify(subject, current_time_seconds);
                                        handshake_state = .trust_chain_established;
                                        break :cert;
                                    },
                                    .bundle => |ca| if (verify: {
                                        try ca.lock.lockShared(ca.io);
                                        defer ca.lock.unlockShared(ca.io);
                                        break :verify ca.bundle.verify(
                                            subject,
                                            current_time_seconds,
                                        );
                                    }) {
                                        handshake_state = .trust_chain_established;
                                        break :cert;
                                    } else |err| switch (err) {
                                        error.CertificateIssuerNotFound => {},
                                        else => |e| return e,
                                    },
                                }

                                previous_certificate = subject;
                                certificate_index = std.math.add(
                                    u16,
                                    certificate_index,
                                    1,
                                ) catch return error.TlsRecordOverflow;
                            }
                            if (!certificates_decoder.eof()) {
                                return error.TlsRecordOverflow;
                            }

                            if (Certificate.Chain != void) {
                                certificates_decoder = certs;
                                for (0..certificate_count_max) |_| {
                                    if (certificates_decoder.eof()) break;
                                    try certificates_decoder.ensure(3);
                                    const certificate_byte_count = certificates_decoder.decode(u24);
                                    const certificate_decoder = try certificates_decoder.sub(
                                        certificate_byte_count,
                                    );
                                    chain.addCert(
                                        certificate_decoder.rest(),
                                    ) catch |err| switch (err) {
                                        error.Unexpected => return error.TlsCertificateNotVerified,
                                    };
                                    if (tls_version == .tls_1_3) {
                                        try certificates_decoder.ensure(2);
                                        const total_extension_byte_count =
                                            certificates_decoder.decode(u16);
                                        const extensions_decoder = try certificates_decoder.sub(
                                            total_extension_byte_count,
                                        );
                                        _ = extensions_decoder;
                                    }
                                }
                                if (!certificates_decoder.eof()) {
                                    return error.TlsRecordOverflow;
                                }
                            }
                        },
                        .server_key_exchange => {
                            if (tls_version != .tls_1_2) return error.TlsUnexpectedMessage;
                            if (cipher_state != .cleartext) return error.TlsUnexpectedMessage;
                            switch (handshake_state) {
                                .trust_chain_established => {},
                                .certificate => try tryDownloadRootCert(&chain, &options),
                                else => return error.TlsUnexpectedMessage,
                            }

                            switch (handshake_cipher) {
                                inline else => |*cipher| {
                                    cipher.transcript_hash.update(wrapped_handshake);
                                },
                            }
                            try handshake_decoder.ensure(1 + 2 + 1);
                            const curve_type = handshake_decoder.decode(u8);
                            if (curve_type != 0x03) return error.TlsIllegalParameter; // named_curve
                            const named_group = handshake_decoder.decode(tls.NamedGroup);
                            tls_1_2_negotiated_group = named_group;
                            const key_byte_count = handshake_decoder.decode(u8);
                            try handshake_decoder.ensure(key_byte_count);
                            const server_public_key = handshake_decoder.slice(key_byte_count);
                            const authentication = tls_1_2_authentication orelse
                                return error.TlsIllegalParameter;
                            if (!main_certificate_public_key.matchesTLS12Authentication(
                                authentication,
                            )) {
                                return error.TlsBadSignatureScheme;
                            }
                            try main_certificate_public_key.verifySignature(
                                tls_version,
                                &handshake_decoder,
                                &.{
                                    &client_hello_random,
                                    &server_hello_random,
                                    handshake_decoder.buf[0..handshake_decoder.idx],
                                },
                            );
                            try key_share.exchange(named_group, server_public_key);
                            handshake_state = .server_hello_done;
                        },
                        .server_hello_done => {
                            if (tls_version != .tls_1_2) return error.TlsUnexpectedMessage;
                            if (cipher_state != .cleartext) return error.TlsUnexpectedMessage;
                            if (handshake_state != .server_hello_done) {
                                return error.TlsUnexpectedMessage;
                            }

                            const negotiated_group =
                                tls_1_2_negotiated_group orelse .secp256r1;
                            const public_key_bytes: []const u8 = switch (negotiated_group) {
                                .secp256r1 => secp256r1: {
                                    const key_pair = &key_share.secp256r1_key_pair;
                                    break :secp256r1 &key_pair.public_key.toUncompressedSec1();
                                },
                                .secp384r1 => secp384r1: {
                                    const key_pair = &key_share.secp384r1_key_pair;
                                    break :secp384r1 &key_pair.public_key.toUncompressedSec1();
                                },
                                .x25519 => &key_share.x25519_key_pair.public_key,
                                else => return error.TlsIllegalParameter,
                            };

                            // These nested lengths keep the record, handshake
                            // body, and public-key vector boundaries aligned.
                            const client_key_exchange_prefix =
                                .{@intFromEnum(tls.ContentType.handshake)} ++
                                int(u16, @intFromEnum(tls.ProtocolVersion.tls_1_2)) ++
                                int(u16, @intCast(public_key_bytes.len + 5)) ++
                                .{@intFromEnum(tls.HandshakeType.client_key_exchange)} ++
                                int(u24, @intCast(public_key_bytes.len + 1)) ++
                                .{@as(u8, @intCast(public_key_bytes.len))};
                            const client_change_cipher_spec_msg =
                                .{@intFromEnum(tls.ContentType.change_cipher_spec)} ++
                                int(u16, @intFromEnum(tls.ProtocolVersion.tls_1_2)) ++
                                array(u16, tls.ChangeCipherSpecType, .{.change_cipher_spec});
                            const pre_master_secret = key_share.getSharedSecret().?;
                            switch (handshake_cipher) {
                                inline else => |*cipher| {
                                    const Cipher = @TypeOf(cipher.*).A;
                                    cipher.transcript_hash.update(wrapped_handshake);
                                    cipher.transcript_hash.update(
                                        client_key_exchange_prefix[tls.record_header_len..],
                                    );
                                    cipher.transcript_hash.update(public_key_bytes);
                                    const master_secret = hmacExpandLabel(
                                        Cipher.Hmac,
                                        pre_master_secret,
                                        &.{
                                            "master secret",
                                            &client_hello_random,
                                            &server_hello_random,
                                        },
                                        48,
                                    );
                                    if (options.ssl_key_log) |key_log| {
                                        try logSecrets(
                                            key_log.writer,
                                            .{
                                                .client_random = &client_hello_random,
                                            },
                                            .{
                                                .CLIENT_RANDOM = &master_secret,
                                            },
                                        );
                                    }
                                    const key_block = hmacExpandLabel(
                                        Cipher.Hmac,
                                        &master_secret,
                                        &.{
                                            "key expansion",
                                            &server_hello_random,
                                            &client_hello_random,
                                        },
                                        @sizeOf(Cipher.Tls_1_2),
                                    );
                                    const client_verify_cleartext =
                                        .{@intFromEnum(tls.HandshakeType.finished)} ++
                                        array(
                                            u24,
                                            u8,
                                            hmacExpandLabel(
                                                Cipher.Hmac,
                                                &master_secret,
                                                &.{
                                                    "client finished",
                                                    &cipher.transcript_hash.peek(),
                                                },
                                                Cipher.verify_data_length,
                                            ),
                                        );
                                    cipher.transcript_hash.update(&client_verify_cleartext);
                                    cipher.version = .{ .tls_1_2 = .{
                                        .expected_server_verify_data = hmacExpandLabel(
                                            Cipher.Hmac,
                                            &master_secret,
                                            &.{
                                                "server finished",
                                                &cipher.transcript_hash.finalResult(),
                                            },
                                            Cipher.verify_data_length,
                                        ),
                                        .app_cipher = mem.bytesToValue(Cipher.Tls_1_2, &key_block),
                                    } };
                                    const state = &cipher.version.tls_1_2;
                                    const nonce: [Cipher.AEAD.nonce_length]u8 = nonce: {
                                        const NonceVector = @Vector(Cipher.AEAD.nonce_length, u8);
                                        const pad = [1]u8{0} ** (Cipher.AEAD.nonce_length - 8);
                                        const operand: NonceVector = pad ++
                                            @as([8]u8, @bitCast(big(write_sequence)));
                                        const nonce_base = @as(
                                            NonceVector,
                                            state.app_cipher.client_write_IV ++
                                                state.app_cipher.client_salt,
                                        );
                                        break :nonce nonce_base ^ operand;
                                    };
                                    const client_verify_payload_len =
                                        client_verify_cleartext.len + Cipher.mac_length;
                                    var client_verify_msg =
                                        .{@intFromEnum(tls.ContentType.handshake)} ++
                                        int(
                                            u16,
                                            @intFromEnum(tls.ProtocolVersion.tls_1_2),
                                        ) ++
                                        array(
                                            u16,
                                            u8,
                                            nonce[Cipher.fixed_iv_length..].* ++
                                                @as(
                                                    [client_verify_payload_len]u8,
                                                    undefined,
                                                ),
                                        );
                                    const ciphertext_start =
                                        client_verify_msg.len -
                                        Cipher.mac_length -
                                        client_verify_cleartext.len;
                                    const ciphertext_output_byte_count =
                                        client_verify_msg.len - Cipher.mac_length;
                                    const ciphertext_tail =
                                        client_verify_msg[ciphertext_start..];
                                    const ciphertext_len = client_verify_cleartext.len;
                                    const ciphertext = ciphertext_tail[0..ciphertext_len];
                                    const auth_tag_start =
                                        ciphertext_output_byte_count;
                                    const auth_tag =
                                        client_verify_msg[auth_tag_start..];
                                    const client_verify_ad =
                                        mem.toBytes(big(write_sequence)) ++
                                        client_verify_msg[0 .. 1 + 2] ++
                                        int(u16, client_verify_cleartext.len);
                                    Cipher.AEAD.encrypt(
                                        ciphertext,
                                        auth_tag,
                                        &client_verify_cleartext,
                                        client_verify_ad,
                                        nonce,
                                        state.app_cipher.client_write_key,
                                    );
                                    var all_message_vectors: [4][]const u8 = .{
                                        &client_key_exchange_prefix,
                                        public_key_bytes,
                                        &client_change_cipher_spec_msg,
                                        &client_verify_msg,
                                    };
                                    try output.writeVecAll(&all_message_vectors);
                                    try output.flush();
                                },
                            }
                            write_sequence = std.math.add(u64, write_sequence, 1) catch
                                return error.TLSSequenceOverflow;
                            pending_cipher_state = .application;
                            handshake_state = .finished;
                        },
                        .certificate_verify => {
                            if (tls_version != .tls_1_3) return error.TlsUnexpectedMessage;
                            if (cipher_state != .handshake) return error.TlsUnexpectedMessage;
                            switch (handshake_state) {
                                .trust_chain_established => {},
                                .certificate => try tryDownloadRootCert(&chain, &options),
                                else => return error.TlsUnexpectedMessage,
                            }
                            switch (handshake_cipher) {
                                inline else => |*cipher| {
                                    try main_certificate_public_key.verifySignature(
                                        tls_version,
                                        &handshake_decoder,
                                        &.{
                                            " " ** 64 ++
                                                "TLS 1.3, server CertificateVerify\x00",
                                            &cipher.transcript_hash.peek(),
                                        },
                                    );
                                    cipher.transcript_hash.update(wrapped_handshake);
                                },
                            }
                            handshake_state = .finished;
                        },
                        .finished => {
                            if (cipher_state == .cleartext) return error.TlsUnexpectedMessage;
                            if (handshake_state != .finished) return error.TlsUnexpectedMessage;
                            // This message is to trick buggy proxies into behaving correctly.
                            const client_change_cipher_spec_msg =
                                .{@intFromEnum(tls.ContentType.change_cipher_spec)} ++
                                int(u16, @intFromEnum(tls.ProtocolVersion.tls_1_2)) ++
                                array(u16, tls.ChangeCipherSpecType, .{.change_cipher_spec});
                            const app_cipher = app_cipher: switch (handshake_cipher) {
                                inline else => |*cipher, tag| switch (tls_version) {
                                    .tls_1_3 => {
                                        const state = &cipher.version.tls_1_3;
                                        const Cipher = @TypeOf(cipher.*).A;
                                        try handshake_decoder.ensure(Cipher.Hmac.mac_length);
                                        const finished_digest = cipher.transcript_hash.peek();
                                        cipher.transcript_hash.update(wrapped_handshake);
                                        const expected_server_verify_data = tls.hmac(
                                            Cipher.Hmac,
                                            &finished_digest,
                                            state.server_finished_key,
                                        );
                                        const received_server_verify_data =
                                            handshake_decoder.array(Cipher.Hmac.mac_length).*;
                                        if (!std.crypto.timing_safe.eql(
                                            [Cipher.Hmac.mac_length]u8,
                                            expected_server_verify_data,
                                            received_server_verify_data,
                                        )) {
                                            return error.TlsDecryptError;
                                        }
                                        const handshake_hash = cipher.transcript_hash.finalResult();
                                        const verify_data = tls.hmac(
                                            Cipher.Hmac,
                                            &handshake_hash,
                                            state.client_finished_key,
                                        );
                                        const out_cleartext =
                                            .{@intFromEnum(tls.HandshakeType.finished)} ++
                                            array(u24, u8, verify_data) ++
                                            .{@intFromEnum(tls.ContentType.handshake)};

                                        const wrapped_len =
                                            out_cleartext.len + Cipher.AEAD.tag_length;

                                        var finished_msg =
                                            .{@intFromEnum(tls.ContentType.application_data)} ++
                                            int(
                                                u16,
                                                @intFromEnum(tls.ProtocolVersion.tls_1_2),
                                            ) ++
                                            array(u16, u8, @as([wrapped_len]u8, undefined));

                                        const additional_data_end =
                                            tls.record_header_len;
                                        const additional_data =
                                            finished_msg[0..additional_data_end];
                                        const finished_payload_start =
                                            tls.record_header_len;
                                        const finished_payload =
                                            finished_msg[finished_payload_start..];
                                        const ciphertext = finished_payload[0..out_cleartext.len];
                                        const tag_start =
                                            finished_msg.len - Cipher.AEAD.tag_length;
                                        const auth_tag = finished_msg[tag_start..];
                                        const nonce = state.client_handshake_iv;
                                        Cipher.AEAD.encrypt(
                                            ciphertext,
                                            auth_tag,
                                            &out_cleartext,
                                            additional_data,
                                            nonce,
                                            state.client_handshake_key,
                                        );

                                        var all_message_vectors: [2][]const u8 = .{
                                            &client_change_cipher_spec_msg,
                                            &finished_msg,
                                        };
                                        try output.writeVecAll(&all_message_vectors);
                                        try output.flush();

                                        const client_secret = hkdfExpandLabel(
                                            Cipher.Hkdf,
                                            state.master_secret,
                                            "c ap traffic",
                                            &handshake_hash,
                                            Cipher.Hash.digest_length,
                                        );
                                        const server_secret = hkdfExpandLabel(
                                            Cipher.Hkdf,
                                            state.master_secret,
                                            "s ap traffic",
                                            &handshake_hash,
                                            Cipher.Hash.digest_length,
                                        );
                                        if (options.ssl_key_log) |key_log| {
                                            try logSecrets(
                                                key_log.writer,
                                                .{
                                                    .counter = key_sequence,
                                                    .client_random = &client_hello_random,
                                                },
                                                .{
                                                    .SERVER_TRAFFIC_SECRET = &server_secret,
                                                    .CLIENT_TRAFFIC_SECRET = &client_secret,
                                                },
                                            );
                                        }
                                        key_sequence += 1;
                                        break :app_cipher @unionInit(
                                            tls.ApplicationCipher,
                                            @tagName(tag),
                                            .{
                                                .tls_1_3 = .{
                                                    .client_secret = client_secret,
                                                    .server_secret = server_secret,
                                                    .client_key = hkdfExpandLabel(
                                                        Cipher.Hkdf,
                                                        client_secret,
                                                        "key",
                                                        "",
                                                        Cipher.AEAD.key_length,
                                                    ),
                                                    .server_key = hkdfExpandLabel(
                                                        Cipher.Hkdf,
                                                        server_secret,
                                                        "key",
                                                        "",
                                                        Cipher.AEAD.key_length,
                                                    ),
                                                    .client_iv = hkdfExpandLabel(
                                                        Cipher.Hkdf,
                                                        client_secret,
                                                        "iv",
                                                        "",
                                                        Cipher.AEAD.nonce_length,
                                                    ),
                                                    .server_iv = hkdfExpandLabel(
                                                        Cipher.Hkdf,
                                                        server_secret,
                                                        "iv",
                                                        "",
                                                        Cipher.AEAD.nonce_length,
                                                    ),
                                                },
                                            },
                                        );
                                    },
                                    .tls_1_2 => {
                                        const state = &cipher.version.tls_1_2;
                                        const Cipher = @TypeOf(cipher.*).A;
                                        try handshake_decoder.ensure(Cipher.verify_data_length);
                                        const received_server_verify_data =
                                            handshake_decoder.array(Cipher.verify_data_length).*;
                                        if (!std.crypto.timing_safe.eql(
                                            [Cipher.verify_data_length]u8,
                                            state.expected_server_verify_data,
                                            received_server_verify_data,
                                        )) {
                                            return error.TlsDecryptError;
                                        }
                                        break :app_cipher @unionInit(
                                            tls.ApplicationCipher,
                                            @tagName(tag),
                                            .{ .tls_1_2 = state.app_cipher },
                                        );
                                    },
                                    else => unreachable,
                                },
                            };
                            if (options.ssl_key_log) |ssl_key_log| ssl_key_log.* = .{
                                .client_key_sequence = key_sequence,
                                .server_key_sequence = key_sequence,
                                .client_random = client_hello_random,
                                .writer = ssl_key_log.writer,
                            };
                            target.* = .{
                                .input = input,
                                .reader = .{
                                    .buffer = options.read_buffer,
                                    .vtable = &.{
                                        .stream = stream,
                                        .readVec = readVec,
                                    },
                                    .seek = 0,
                                    .end = 0,
                                },
                                .output = output,
                                .writer = .{
                                    .buffer = options.write_buffer,
                                    .vtable = &.{
                                        .drain = drain,
                                        .flush = flush,
                                    },
                                },
                                .tls_version = tls_version,
                                .read_sequence = switch (tls_version) {
                                    .tls_1_3 => 0,
                                    .tls_1_2 => read_sequence,
                                    else => unreachable,
                                },
                                .write_sequence = switch (tls_version) {
                                    .tls_1_3 => 0,
                                    .tls_1_2 => write_sequence,
                                    else => unreachable,
                                },
                                .received_close_notify = false,
                                .received_user_canceled = false,
                                .application_cipher = app_cipher,
                                .write_error = null,
                                .ssl_key_log = options.ssl_key_log,
                                .alert_parser = .{},
                            };
                            return;
                        },
                        else => return error.TlsUnexpectedMessage,
                    }
                    handshake_fragments.advanceConsumed(content_decoder.idx);
                    if (content_decoder.eof()) {
                        handshake_fragments.reset();
                        break;
                    }
                    // A fresh view keeps every decoder index relative to unconsumed bytes.
                    content_decoder = handshake_fragments.decoder();
                }
                if (!content_decoder.eof()) {
                    return error.TlsHandshakeMessageLimitExceeded;
                }
            },
            else => return error.TlsUnexpectedMessage,
        }
    }
    return error.TlsHandshakeRecordLimitExceeded;
}

fn consumeCompatibilityChangeCipherSpec(
    decoder: *tls.Decoder,
    record_byte_count: u16,
) error{ TlsDecodeError, TlsIllegalParameter }!void {
    if (record_byte_count != 1) return error.TlsIllegalParameter;
    try decoder.ensure(1);
    const compatibility_value = decoder.decode(tls.ChangeCipherSpecType);
    if (compatibility_value != .change_cipher_spec) {
        return error.TlsIllegalParameter;
    }
    if (!decoder.eof()) return error.TlsIllegalParameter;
}

fn drain(
    writer: *Writer,
    data: []const []const u8,
    splat_count: usize,
) Writer.Error!usize {
    assert(data.len > 0);
    const client: *Client = @alignCast(@fieldParentPtr("writer", writer));
    const output = client.output;
    const ciphertext_buffer = try output.writableSliceGreedy(min_buffer_len);
    var ciphertext_output_byte_count: usize = 0;
    var plaintext_byte_count: usize = 0;
    var write_sequence_next = client.write_sequence;
    done: {
        {
            const plaintext_buffer = writer.buffered();
            const prepared = try prepareCiphertextRecord(
                client,
                ciphertext_buffer[ciphertext_output_byte_count..],
                plaintext_buffer,
                .application_data,
                write_sequence_next,
            );
            write_sequence_next = prepared.write_sequence_next;
            plaintext_byte_count += prepared.plaintext_byte_count;
            ciphertext_output_byte_count += prepared.ciphertext_output_byte_count;
            if (prepared.plaintext_byte_count < plaintext_buffer.len) break :done;
        }

        const vector_count = @min(data.len, writer_vector_count_max);
        const includes_splat_pattern = vector_count == data.len;
        const ordinary_vector_count = if (includes_splat_pattern)
            vector_count - 1
        else
            vector_count;
        for (0..writer_vector_count_max) |vector_index| {
            if (vector_index == ordinary_vector_count) break;
            const plaintext_buffer = data[vector_index];
            const prepared = try prepareCiphertextRecord(
                client,
                ciphertext_buffer[ciphertext_output_byte_count..],
                plaintext_buffer,
                .application_data,
                write_sequence_next,
            );
            write_sequence_next = prepared.write_sequence_next;
            plaintext_byte_count += prepared.plaintext_byte_count;
            ciphertext_output_byte_count += prepared.ciphertext_output_byte_count;
            if (prepared.plaintext_byte_count < plaintext_buffer.len) break :done;
        }
        if (includes_splat_pattern) {
            const pattern = data[data.len - 1];
            const repetition_count = @min(
                splat_count,
                writer_splat_count_max,
            );
            if (pattern.len > 0) {
                for (0..writer_splat_count_max) |repetition_index| {
                    if (repetition_index == repetition_count) break;
                    const prepared = try prepareCiphertextRecord(
                        client,
                        ciphertext_buffer[ciphertext_output_byte_count..],
                        pattern,
                        .application_data,
                        write_sequence_next,
                    );
                    write_sequence_next = prepared.write_sequence_next;
                    plaintext_byte_count += prepared.plaintext_byte_count;
                    ciphertext_output_byte_count += prepared.ciphertext_output_byte_count;
                    if (prepared.plaintext_byte_count < pattern.len) break :done;
                }
            }
        }
    }
    output.advance(ciphertext_output_byte_count);
    client.write_sequence = write_sequence_next;
    return writer.consume(plaintext_byte_count);
}

fn flush(writer: *Writer) Writer.Error!void {
    assert(writer.buffer.len == min_buffer_len);
    for (0..flush_iteration_count_max) |_| {
        if (writer.end == 0) return;
        const buffered_len_before = writer.end;
        const data_consumed = try drain(writer, &.{""}, 1);
        assert(data_consumed == 0);
        assert(writer.end < buffered_len_before);
    }
    assert(writer.end == 0);
}

/// Sends a `close_notify` alert, which is necessary for the server to
/// distinguish between a properly finished TLS session, or a truncation
/// attack.
pub fn end(client: *Client) Writer.Error!void {
    try flush(&client.writer);
    const output = client.output;
    const ciphertext_buffer = try output.writableSliceGreedy(min_buffer_len);
    const prepared = try prepareCiphertextRecord(
        client,
        ciphertext_buffer,
        &tls.close_notify_alert,
        .alert,
        client.write_sequence,
    );
    output.advance(prepared.ciphertext_output_byte_count);
    client.write_sequence = prepared.write_sequence_next;
}

fn handleRequestedKeyUpdate(client: *Client) KeyUpdateError!void {
    try sendKeyUpdateResponse(client);
    switch (client.application_cipher) {
        inline else => |*cipher| {
            const state = &cipher.tls_1_3;
            const Cipher = @TypeOf(cipher.*);
            const client_secret = hkdfExpandLabel(
                Cipher.Hkdf,
                state.client_secret,
                "traffic upd",
                "",
                Cipher.Hash.digest_length,
            );
            if (client.ssl_key_log) |key_log| try logSecrets(key_log.writer, .{
                .counter = try key_log.clientCounter(),
                .client_random = &key_log.client_random,
            }, .{
                .CLIENT_TRAFFIC_SECRET = &client_secret,
            });
            state.client_secret = client_secret;
            state.client_key = hkdfExpandLabel(
                Cipher.Hkdf,
                client_secret,
                "key",
                "",
                Cipher.AEAD.key_length,
            );
            state.client_iv = hkdfExpandLabel(
                Cipher.Hkdf,
                client_secret,
                "iv",
                "",
                Cipher.AEAD.nonce_length,
            );
        },
    }
    client.write_sequence = 0;
}

fn sendKeyUpdateResponse(client: *Client) Writer.Error!void {
    const message = [_]u8{
        @intFromEnum(tls.HandshakeType.key_update),
        0,
        0,
        1,
        @intFromEnum(tls.KeyUpdateRequest.update_not_requested),
    };
    const output = client.output;
    const ciphertext = try output.writableSliceGreedy(min_buffer_len);
    const prepared = try prepareCiphertextRecord(
        client,
        ciphertext,
        &message,
        .handshake,
        client.write_sequence,
    );
    assert(prepared.plaintext_byte_count == message.len);
    output.advance(prepared.ciphertext_output_byte_count);
    client.write_sequence = prepared.write_sequence_next;
    try output.flush();
}

fn prepareCiphertextRecord(
    client: *Client,
    ciphertext_buffer: []u8,
    bytes: []const u8,
    inner_content_type: tls.ContentType,
    write_sequence_initial: u64,
) Writer.Error!PreparedCiphertext {
    return switch (client.application_cipher) {
        inline else => |*cipher| switch (client.tls_version) {
            .tls_1_3 => prepareTLS13CiphertextRecords(@TypeOf(cipher.*), .{
                .ciphertext_buffer = ciphertext_buffer,
                .plaintext_buffer = bytes,
                .inner_content_type = inner_content_type,
                .write_sequence_initial = write_sequence_initial,
                .cipher_state = &cipher.tls_1_3,
            }),
            .tls_1_2 => prepareTLS12CiphertextRecords(@TypeOf(cipher.*), .{
                .ciphertext_buffer = ciphertext_buffer,
                .plaintext_buffer = bytes,
                .inner_content_type = inner_content_type,
                .write_sequence_initial = write_sequence_initial,
                .cipher_state = &cipher.tls_1_2,
            }),
            else => unreachable,
        },
    } catch |err| return failWrite(client, err);
}

fn prepareTLS13CiphertextRecords(
    comptime Cipher: type,
    options: struct {
        ciphertext_buffer: []u8,
        plaintext_buffer: []const u8,
        inner_content_type: tls.ContentType,
        write_sequence_initial: u64,
        cipher_state: *const Cipher.Tls_1_3,
    },
) WriteError!PreparedCiphertext {
    // Due to the trailing inner content type byte in the ciphertext, TLS 1.3
    // needs an additional buffer for storing the cleartext before encrypting.
    var cleartext_buffer: [max_ciphertext_len]u8 = undefined;
    var ciphertext_output_byte_count: usize = 0;
    var plaintext_byte_index: usize = 0;
    var write_sequence = options.write_sequence_initial;
    const overhead_len = tls.record_header_len + Cipher.AEAD.tag_length + 1;
    for (0..ciphertext_record_count_max) |_| {
        const encrypted_content_len: u16 = @min(
            options.plaintext_buffer.len - plaintext_byte_index,
            tls.max_ciphertext_inner_record_len,
            options.ciphertext_buffer.len -|
                (overhead_len + ciphertext_output_byte_count),
        );
        if (encrypted_content_len == 0) return .{
            .ciphertext_output_byte_count = ciphertext_output_byte_count,
            .plaintext_byte_count = plaintext_byte_index,
            .write_sequence_next = write_sequence,
        };

        const current_write_sequence = write_sequence;
        const next_write_sequence = std.math.add(
            u64,
            current_write_sequence,
            1,
        ) catch return error.TLSSequenceOverflow;
        @memcpy(
            cleartext_buffer[0..encrypted_content_len],
            options.plaintext_buffer[plaintext_byte_index..][0..encrypted_content_len],
        );
        cleartext_buffer[encrypted_content_len] = @intFromEnum(options.inner_content_type);
        plaintext_byte_index += encrypted_content_len;
        const ciphertext_len = encrypted_content_len + 1;
        const cleartext = cleartext_buffer[0..ciphertext_len];

        const header_output = options.ciphertext_buffer[ciphertext_output_byte_count..];
        const additional_data = header_output[0..tls.record_header_len];
        additional_data.* = .{@intFromEnum(tls.ContentType.application_data)} ++
            int(u16, @intFromEnum(tls.ProtocolVersion.tls_1_2)) ++
            int(u16, ciphertext_len + Cipher.AEAD.tag_length);
        ciphertext_output_byte_count += additional_data.len;
        const ciphertext_output = options.ciphertext_buffer[ciphertext_output_byte_count..];
        const ciphertext = ciphertext_output[0..ciphertext_len];
        ciphertext_output_byte_count += ciphertext_len;
        const auth_tag_output = options.ciphertext_buffer[ciphertext_output_byte_count..];
        const auth_tag = auth_tag_output[0..Cipher.AEAD.tag_length];
        ciphertext_output_byte_count += auth_tag.len;
        const nonce = nonce: {
            const NonceVector = @Vector(Cipher.AEAD.nonce_length, u8);
            const pad = [1]u8{0} ** (Cipher.AEAD.nonce_length - 8);
            const operand: NonceVector = pad ++
                mem.toBytes(big(current_write_sequence));
            break :nonce @as(NonceVector, options.cipher_state.client_iv) ^ operand;
        };
        Cipher.AEAD.encrypt(
            ciphertext,
            auth_tag,
            cleartext,
            additional_data,
            nonce,
            options.cipher_state.client_key,
        );
        write_sequence = next_write_sequence;
    }
    return .{
        .ciphertext_output_byte_count = ciphertext_output_byte_count,
        .plaintext_byte_count = plaintext_byte_index,
        .write_sequence_next = write_sequence,
    };
}

fn prepareTLS12CiphertextRecords(
    comptime Cipher: type,
    options: struct {
        ciphertext_buffer: []u8,
        plaintext_buffer: []const u8,
        inner_content_type: tls.ContentType,
        write_sequence_initial: u64,
        cipher_state: *const Cipher.Tls_1_2,
    },
) WriteError!PreparedCiphertext {
    var cleartext_buffer: [max_ciphertext_len]u8 = undefined;
    var ciphertext_output_byte_count: usize = 0;
    var plaintext_byte_index: usize = 0;
    var write_sequence = options.write_sequence_initial;
    const cipher_overhead_len = Cipher.record_iv_length + Cipher.mac_length;
    const overhead_len = tls.record_header_len + cipher_overhead_len;
    for (0..ciphertext_record_count_max) |_| {
        const message_len: u16 = @min(
            options.plaintext_buffer.len - plaintext_byte_index,
            tls.max_ciphertext_inner_record_len,
            options.ciphertext_buffer.len -|
                (overhead_len + ciphertext_output_byte_count),
        );
        if (message_len == 0) return .{
            .ciphertext_output_byte_count = ciphertext_output_byte_count,
            .plaintext_byte_count = plaintext_byte_index,
            .write_sequence_next = write_sequence,
        };

        const current_write_sequence = write_sequence;
        const next_write_sequence = std.math.add(
            u64,
            current_write_sequence,
            1,
        ) catch return error.TLSSequenceOverflow;
        @memcpy(
            cleartext_buffer[0..message_len],
            options.plaintext_buffer[plaintext_byte_index..][0..message_len],
        );
        plaintext_byte_index += message_len;
        const cleartext = cleartext_buffer[0..message_len];

        const ciphertext_tail = options.ciphertext_buffer[ciphertext_output_byte_count..];
        const record_header = ciphertext_tail[0..tls.record_header_len];
        ciphertext_output_byte_count += tls.record_header_len;
        record_header.* = .{@intFromEnum(options.inner_content_type)} ++
            int(u16, @intFromEnum(tls.ProtocolVersion.tls_1_2)) ++
            int(u16, Cipher.record_iv_length + message_len + Cipher.mac_length);
        const additional_data = mem.toBytes(big(current_write_sequence)) ++
            record_header[0 .. 1 + 2] ++ int(u16, message_len);
        const record_iv_output = options.ciphertext_buffer[ciphertext_output_byte_count..];
        const record_iv = record_iv_output[0..Cipher.record_iv_length];
        ciphertext_output_byte_count += Cipher.record_iv_length;
        const nonce: [Cipher.AEAD.nonce_length]u8 = nonce: {
            const NonceVector = @Vector(Cipher.AEAD.nonce_length, u8);
            const pad = [1]u8{0} ** (Cipher.AEAD.nonce_length - 8);
            const operand: NonceVector = pad ++
                @as([8]u8, @bitCast(big(current_write_sequence)));
            const nonce_base = @as(
                NonceVector,
                options.cipher_state.client_write_IV ++ options.cipher_state.client_salt,
            );
            break :nonce nonce_base ^ operand;
        };
        record_iv.* = nonce[Cipher.fixed_iv_length..].*;
        const ciphertext_output = options.ciphertext_buffer[ciphertext_output_byte_count..];
        const ciphertext = ciphertext_output[0..message_len];
        ciphertext_output_byte_count += message_len;
        const auth_tag_output = options.ciphertext_buffer[ciphertext_output_byte_count..];
        const auth_tag = auth_tag_output[0..Cipher.mac_length];
        ciphertext_output_byte_count += Cipher.mac_length;
        Cipher.AEAD.encrypt(
            ciphertext,
            auth_tag,
            cleartext,
            additional_data,
            nonce,
            options.cipher_state.client_write_key,
        );
        write_sequence = next_write_sequence;
    }
    return .{
        .ciphertext_output_byte_count = ciphertext_output_byte_count,
        .plaintext_byte_count = plaintext_byte_index,
        .write_sequence_next = write_sequence,
    };
}

pub fn eof(client: *const Client) bool {
    return client.received_close_notify;
}

fn stream(reader: *Reader, writer: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
    // This function writes exclusively to the buffer.
    _ = writer;
    _ = limit;
    const client: *Client = @alignCast(@fieldParentPtr("reader", reader));
    return readIndirect(client);
}

fn readVec(reader: *Reader, data: [][]u8) Reader.Error!usize {
    // This function writes exclusively to the buffer.
    _ = data;
    const client: *Client = @alignCast(@fieldParentPtr("reader", reader));
    return readIndirect(client);
}

pub fn readOneRecord(client: *Client) Reader.Error!RecordEvent {
    if (client.reader.bufferedLen() > 0) return .application_data;
    client.last_record_event = .need_more;
    const read_count = readIndirect(client) catch |err| switch (err) {
        error.EndOfStream => return .eof,
        else => |other| return other,
    };
    // Reader callbacks append plaintext to their buffer and report zero direct
    // bytes because this seam does not write into a caller-provided slice.
    assert(read_count == 0);
    return client.last_record_event;
}

fn readIndirect(client: *Client) Reader.Error!usize {
    const reader = &client.reader;
    if (client.eof()) return error.EndOfStream;
    const input = client.input;
    // If at least one full encrypted record is not buffered, read once.
    const record_header = input.peek(tls.record_header_len) catch |err| switch (err) {
        error.EndOfStream => {
            // This is either a truncation attack, a bug in the server, or an
            // intentional omission of the close_notify message due to truncation
            // detection handled above the TLS layer.
            return failRead(client, error.TLSConnectionTruncated);
        },
        error.ReadFailed => return error.ReadFailed,
    };
    const content_type: tls.ContentType = @enumFromInt(record_header[0]);
    const legacy_version = mem.readInt(u16, record_header[1..][0..2], .big);
    _ = legacy_version;
    const record_byte_count = mem.readInt(u16, record_header[3..][0..2], .big);
    if (record_byte_count > max_ciphertext_len) return failRead(client, error.TlsRecordOverflow);
    const record_end = 5 + record_byte_count;
    if (record_end > input.buffered().len) {
        input.fillMore() catch |err| switch (err) {
            error.EndOfStream => return failRead(client, error.TLSConnectionTruncated),
            error.ReadFailed => return error.ReadFailed,
        };
        if (record_end > input.buffered().len) return 0;
    }

    const decrypted_record = switch (client.application_cipher) {
        inline else => |*cipher| switch (client.tls_version) {
            .tls_1_3 => decryptTLS13CiphertextRecord(@TypeOf(cipher.*), .{
                .input = input,
                .plaintext_reader = reader,
                .record_byte_count = record_byte_count,
                .read_sequence = client.read_sequence,
                .cipher_state = &cipher.tls_1_3,
            }),
            .tls_1_2 => decryptTLS12CiphertextRecord(@TypeOf(cipher.*), .{
                .input = input,
                .plaintext_reader = reader,
                .record_content_type = content_type,
                .record_byte_count = record_byte_count,
                .read_sequence = client.read_sequence,
                .cipher_state = &cipher.tls_1_2,
            }),
            else => unreachable,
        },
    } catch |err| return failRead(client, err);
    const plaintext_byte_count = decrypted_record.plaintext_byte_count;
    const inner_content_type = decrypted_record.inner_content_type;
    const cleartext = reader.buffer[reader.end..][0..plaintext_byte_count];
    client.read_sequence = std.math.add(
        u64,
        client.read_sequence,
        1,
    ) catch return failRead(client, error.TLSSequenceOverflow);
    if (!client.alert_parser.isIdle()) {
        if (inner_content_type != .alert) {
            return failRead(client, error.TlsUnexpectedMessage);
        }
    }
    if (client.received_user_canceled) {
        if (inner_content_type != .alert) {
            return failRead(client, error.TlsUnexpectedMessage);
        }
    }
    switch (inner_content_type) {
        .alert => {
            if (!postHandshakeIdle(client)) {
                return failRead(client, error.TlsUnexpectedMessage);
            }
            if (client.tls_version == .tls_1_3) {
                if (cleartext.len != 2) {
                    return failRead(client, error.TlsDecodeError);
                }
                const alert: tls.Alert = .{
                    .level = @enumFromInt(cleartext[0]),
                    .description = @enumFromInt(cleartext[1]),
                };
                const outcome = try handleAlert(
                    client,
                    client.tls_version,
                    alert,
                );
                if (outcome == .eof) return 0;
                client.last_record_event = .control;
                return 0;
            }

            var alert_byte_index: usize = 0;
            for (0..alert_count_max) |_| {
                if (alert_byte_index == cleartext.len) break;
                const alert = client.alert_parser.next(
                    cleartext,
                    &alert_byte_index,
                ) orelse break;
                const outcome = try handleAlert(
                    client,
                    client.tls_version,
                    alert,
                );
                if (outcome == .eof) return 0;
            }
            if (alert_byte_index != cleartext.len) {
                return failRead(client, error.TlsRecordOverflow);
            }
            client.last_record_event = .control;
            return 0;
        },
        .handshake => {
            const result = try processPostHandshake(client, cleartext);
            client.last_record_event = .control;
            return result;
        },
        .application_data => {
            if (!postHandshakeIdle(client)) {
                return failRead(client, error.TlsUnexpectedMessage);
            }
            reader.end += cleartext.len;
            client.last_record_event = if (cleartext.len == 0)
                .control
            else
                .application_data;
            return 0;
        },
        else => return failRead(client, error.TlsUnexpectedMessage),
    }
}

fn decryptTLS13CiphertextRecord(
    comptime Cipher: type,
    options: struct {
        input: *Reader,
        plaintext_reader: *Reader,
        record_byte_count: u16,
        read_sequence: u64,
        cipher_state: *const Cipher.Tls_1_3,
    },
) DecryptRecordError!DecryptedRecord {
    if (options.record_byte_count < Cipher.AEAD.tag_length + 1) {
        return error.TlsDecodeError;
    }
    // The caller's preceding peek guarantees these record slices exist.
    const additional_data = options.input.take(tls.record_header_len) catch unreachable;
    const ciphertext_len = options.record_byte_count - Cipher.AEAD.tag_length;
    const ciphertext = options.input.take(ciphertext_len) catch unreachable;
    const auth_tag = (options.input.takeArray(Cipher.AEAD.tag_length) catch unreachable).*;
    const nonce = nonce: {
        const NonceVector = @Vector(Cipher.AEAD.nonce_length, u8);
        const pad = [1]u8{0} ** (Cipher.AEAD.nonce_length - 8);
        const operand: NonceVector = pad ++ mem.toBytes(big(options.read_sequence));
        break :nonce @as(NonceVector, options.cipher_state.server_iv) ^ operand;
    };
    rebase(options.plaintext_reader, ciphertext.len);
    const plaintext_output =
        options.plaintext_reader.buffer[options.plaintext_reader.end..];
    const cleartext = plaintext_output[0..ciphertext.len];
    Cipher.AEAD.decrypt(
        cleartext,
        ciphertext,
        auth_tag,
        additional_data,
        nonce,
        options.cipher_state.server_key,
    ) catch return error.TlsBadRecordMac;
    // Decoder currently exposes only the slice-based operation.
    const message = mem.trimEnd(u8, cleartext, "\x00");
    if (message.len == 0) return error.TlsDecodeError;
    const content_byte_count = message.len - 1;
    if (content_byte_count > tls.max_ciphertext_inner_record_len) {
        return error.TlsRecordOverflow;
    }
    return .{
        .plaintext_byte_count = content_byte_count,
        .inner_content_type = @enumFromInt(message[message.len - 1]),
    };
}

fn decryptTLS12CiphertextRecord(
    comptime Cipher: type,
    options: struct {
        input: *Reader,
        plaintext_reader: *Reader,
        record_content_type: tls.ContentType,
        record_byte_count: u16,
        read_sequence: u64,
        cipher_state: *const Cipher.Tls_1_2,
    },
) DecryptRecordError!DecryptedRecord {
    if (options.record_byte_count < Cipher.record_iv_length + Cipher.mac_length) {
        return error.TlsDecodeError;
    }
    const cipher_overhead = Cipher.record_iv_length + Cipher.mac_length;
    const message_len: u16 = options.record_byte_count - cipher_overhead;
    if (message_len > tls.max_ciphertext_inner_record_len) {
        return error.TlsRecordOverflow;
    }
    // The caller's preceding peek guarantees these record slices exist.
    const additional_data_header = options.input.take(tls.record_header_len) catch unreachable;
    const additional_data = mem.toBytes(big(options.read_sequence)) ++
        additional_data_header[0 .. 1 + 2] ++
        mem.toBytes(big(message_len));
    const record_iv = (options.input.takeArray(Cipher.record_iv_length) catch unreachable).*;
    const masked_read_sequence = options.read_sequence &
        comptime std.math.shl(u64, std.math.maxInt(u64), 8 * Cipher.record_iv_length);
    const nonce: [Cipher.AEAD.nonce_length]u8 = nonce: {
        const NonceVector = @Vector(Cipher.AEAD.nonce_length, u8);
        const pad = [1]u8{0} ** (Cipher.AEAD.nonce_length - 8);
        const sequence_bytes = @as(
            [8]u8,
            @bitCast(big(masked_read_sequence)),
        );
        const operand: NonceVector = pad ++ sequence_bytes;
        const nonce_base = @as(
            NonceVector,
            options.cipher_state.server_write_IV ++ record_iv,
        );
        break :nonce nonce_base ^ operand;
    };
    const ciphertext = options.input.take(message_len) catch unreachable;
    const auth_tag = (options.input.takeArray(Cipher.mac_length) catch unreachable).*;
    rebase(options.plaintext_reader, ciphertext.len);
    const plaintext_output =
        options.plaintext_reader.buffer[options.plaintext_reader.end..];
    const cleartext = plaintext_output[0..ciphertext.len];
    Cipher.AEAD.decrypt(
        cleartext,
        ciphertext,
        auth_tag,
        additional_data,
        nonce,
        options.cipher_state.server_write_key,
    ) catch return error.TlsBadRecordMac;
    return .{
        .plaintext_byte_count = cleartext.len,
        .inner_content_type = options.record_content_type,
    };
}

fn handleAlert(
    client: *Client,
    tls_version: tls.ProtocolVersion,
    alert: tls.Alert,
) error{ReadFailed}!AlertOutcome {
    switch (alert.description) {
        .close_notify => {
            client.received_close_notify = true;
            client.last_record_event = .eof;
            return .eof;
        },
        .user_canceled => {
            if (tls_version == .tls_1_2) {
                if (alert.level != .warning) {
                    client.alert = alert;
                    return failRead(client, error.TlsAlert);
                }
            }
            client.received_user_canceled = true;
            return .control;
        },
        else => {
            client.alert = alert;
            return failRead(client, error.TlsAlert);
        },
    }
}

fn postHandshakeIdle(client: *const Client) bool {
    if (client.post_handshake.kind != .header) return false;
    return client.post_handshake.header_len == 0;
}

fn processPostHandshake(
    client: *Client,
    cleartext: []const u8,
) error{ReadFailed}!usize {
    if (client.tls_version != .tls_1_3) {
        return failRead(client, error.TlsUnexpectedMessage);
    }
    if (cleartext.len == 0) {
        return failRead(client, error.TlsDecodeError);
    }

    var cleartext_byte_index: usize = 0;
    for (0..post_handshake_step_count_max) |_| {
        if (cleartext_byte_index == cleartext.len) break;
        switch (client.post_handshake.kind) {
            .header => {
                const header_len: usize = client.post_handshake.header_len;
                const byte_count_to_take = @min(
                    client.post_handshake.header.len - header_len,
                    cleartext.len - cleartext_byte_index,
                );
                @memcpy(
                    client.post_handshake.header[header_len..][0..byte_count_to_take],
                    cleartext[cleartext_byte_index..][0..byte_count_to_take],
                );
                client.post_handshake.header_len += @intCast(byte_count_to_take);
                cleartext_byte_index += byte_count_to_take;
                if (client.post_handshake.header_len <
                    client.post_handshake.header.len)
                {
                    continue;
                }

                const handshake_type: tls.HandshakeType =
                    @enumFromInt(client.post_handshake.header[0]);
                const handshake_len = mem.readInt(
                    u24,
                    client.post_handshake.header[1..4],
                    .big,
                );
                client.post_handshake.header_len = 0;
                client.post_handshake.remaining = handshake_len;
                switch (handshake_type) {
                    .new_session_ticket => {
                        client.post_handshake.kind = .new_session_ticket;
                        if (handshake_len == 0) {
                            client.post_handshake.kind = .header;
                        }
                    },
                    .key_update => {
                        if (handshake_len != 1) {
                            return failRead(client, error.TlsBadLength);
                        }
                        client.post_handshake.kind = .key_update;
                    },
                    else => return failRead(client, error.TlsUnexpectedMessage),
                }
            },
            .new_session_ticket => {
                const byte_count_to_take: u24 = @intCast(@min(
                    client.post_handshake.remaining,
                    cleartext.len - cleartext_byte_index,
                ));
                client.post_handshake.remaining -= byte_count_to_take;
                cleartext_byte_index += byte_count_to_take;
                if (client.post_handshake.remaining == 0) {
                    client.post_handshake.kind = .header;
                }
            },
            .key_update => {
                std.debug.assert(client.post_handshake.remaining == 1);
                client.post_handshake.key_update_request = cleartext[cleartext_byte_index];
                client.post_handshake.remaining = 0;
                client.post_handshake.kind = .header;
                cleartext_byte_index += 1;

                // A key change must align with the TLS record boundary. Bytes after
                // KeyUpdate in this record would still use the old read key.
                if (cleartext_byte_index != cleartext.len) {
                    return failRead(client, error.TlsUnexpectedMessage);
                }
                const request: tls.KeyUpdateRequest =
                    @enumFromInt(client.post_handshake.key_update_request);
                switch (request) {
                    .update_requested, .update_not_requested => {},
                    _ => return failRead(client, error.TlsIllegalParameter),
                }
                applyPeerKeyUpdate(client, request) catch |err| switch (err) {
                    error.TLSSequenceOverflow => {
                        return failRead(client, error.TLSSequenceOverflow);
                    },
                    else => return failRead(
                        client,
                        error.TlsKeyUpdateWriteFailed,
                    ),
                };
            },
        }
    }
    std.debug.assert(cleartext_byte_index == cleartext.len);
    return 0;
}

fn applyPeerKeyUpdate(
    client: *Client,
    request: tls.KeyUpdateRequest,
) KeyUpdateError!void {
    switch (client.application_cipher) {
        inline else => |*cipher| {
            const state = &cipher.tls_1_3;
            const Cipher = @TypeOf(cipher.*);
            const server_secret = hkdfExpandLabel(
                Cipher.Hkdf,
                state.server_secret,
                "traffic upd",
                "",
                Cipher.Hash.digest_length,
            );
            if (client.ssl_key_log) |key_log| try logSecrets(key_log.writer, .{
                .counter = try key_log.serverCounter(),
                .client_random = &key_log.client_random,
            }, .{
                .SERVER_TRAFFIC_SECRET = &server_secret,
            });
            state.server_secret = server_secret;
            state.server_key = hkdfExpandLabel(
                Cipher.Hkdf,
                server_secret,
                "key",
                "",
                Cipher.AEAD.key_length,
            );
            state.server_iv = hkdfExpandLabel(
                Cipher.Hkdf,
                server_secret,
                "iv",
                "",
                Cipher.AEAD.nonce_length,
            );
        },
    }
    client.read_sequence = 0;
    if (request == .update_requested) {
        try handleRequestedKeyUpdate(client);
    }
}

fn rebase(reader: *Reader, capacity: usize) void {
    if (reader.buffer.len - reader.end >= capacity) return;
    const data = reader.buffer[reader.seek..reader.end];
    @memmove(reader.buffer[0..data.len], data);
    reader.seek = 0;
    reader.end = data.len;
    assert(reader.buffer.len - reader.end >= capacity);
}

fn failWrite(client: *Client, err: WriteError) error{WriteFailed} {
    client.write_error = err;
    return error.WriteFailed;
}

fn failRead(client: *Client, err: ReadError) error{ReadFailed} {
    client.read_error = err;
    return error.ReadFailed;
}

fn logSecrets(
    writer: *Writer,
    context: anytype,
    secrets: anytype,
) Writer.Error!void {
    inline for (@typeInfo(@TypeOf(secrets)).@"struct".fields) |field| {
        try writer.print(
            "{s}" ++
                (if (@hasField(@TypeOf(context), "counter")) "_{d}" else "") ++
                " {x} {x}\n",
            .{field.name} ++
                (if (@hasField(@TypeOf(context), "counter"))
                    .{context.counter}
                else
                    .{}) ++ .{
                context.client_random,
                @field(secrets, field.name),
            },
        );
    }
}

fn big(x: anytype) @TypeOf(x) {
    return switch (native_endian) {
        .big => x,
        .little => @byteSwap(x),
    };
}

fn tryDownloadRootCert(chain: *Certificate.Chain, options: *const Options) !void {
    if (Certificate.Chain != void) switch (options.ca) {
        else => {},
        .bundle => {
            chain.verify(options.realtime_now) catch |err| switch (err) {
                error.Unexpected => return error.TlsCertificateNotVerified,
                else => |verify_error| return verify_error,
            };
            // OS verification is authoritative here; refreshing shared roots
            // inside a deadline-bound handshake would make cancellation unbounded.
            return;
        },
    };
    return error.TlsCertificateNotVerified;
}

/// The priority order here is chosen based on what crypto algorithms Zig has
/// available in the standard library as well as what is faster. Following are
/// a few data points on the relative performance of these algorithms.
///
/// Measurement taken with 0.11.0-dev.810+c2f5848fe
/// on x86_64-linux Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz:
/// zig run .lib/std/crypto/benchmark.zig -OReleaseFast
///       aegis-128l:      15382 MiB/s
///        aegis-256:       9553 MiB/s
///       aes128-gcm:       3721 MiB/s
///       aes256-gcm:       3010 MiB/s
/// chacha20Poly1305:        597 MiB/s
///
/// Measurement taken with 0.11.0-dev.810+c2f5848fe
/// on x86_64-linux Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz:
/// zig run .lib/std/crypto/benchmark.zig -OReleaseFast -mcpu=baseline
///       aegis-128l:        629 MiB/s
/// chacha20Poly1305:        529 MiB/s
///        aegis-256:        461 MiB/s
///       aes128-gcm:        138 MiB/s
///       aes256-gcm:        120 MiB/s
const cipher_suites = if (crypto.core.aes.has_hardware_support)
    array(u16, tls.CipherSuite, .{
        .AEGIS_128L_SHA256,
        .AEGIS_256_SHA512,
        .AES_128_GCM_SHA256,
        .ECDHE_RSA_WITH_AES_128_GCM_SHA256,
        .ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
        .AES_256_GCM_SHA384,
        .ECDHE_RSA_WITH_AES_256_GCM_SHA384,
        .ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
        .CHACHA20_POLY1305_SHA256,
        .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
        .ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
    })
else
    array(u16, tls.CipherSuite, .{
        .CHACHA20_POLY1305_SHA256,
        .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
        .ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
        .AEGIS_128L_SHA256,
        .AEGIS_256_SHA512,
        .AES_128_GCM_SHA256,
        .ECDHE_RSA_WITH_AES_128_GCM_SHA256,
        .ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
        .AES_256_GCM_SHA384,
        .ECDHE_RSA_WITH_AES_256_GCM_SHA384,
        .ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
    });

fn verifyDeterministicECDSA(
    comptime Curve: type,
    comptime Hash: type,
    tls_version: tls.ProtocolVersion,
    scheme: tls.SignatureScheme,
    seed_byte: u8,
) !void {
    const ECDSA = crypto.sign.ecdsa.Ecdsa(Curve, Hash);
    const key_pair = try ECDSA.KeyPair.generateDeterministic(
        [_]u8{seed_byte} ** ECDSA.KeyPair.seed_length,
    );
    const message = "client-randomserver-randomtranscript";
    const signature = try key_pair.sign(message, null);
    var der_buffer: [ECDSA.Signature.der_encoded_length_max]u8 = undefined;
    const der = signature.toDer(&der_buffer);
    var encoded: [4 + der_buffer.len]u8 = undefined;
    mem.writeInt(u16, encoded[0..2], @intFromEnum(scheme), .big);
    mem.writeInt(u16, encoded[2..4], @intCast(der.len), .big);
    @memcpy(encoded[4..][0..der.len], der);

    var signature_decoder = tls.Decoder.fromTheirSlice(encoded[0 .. 4 + der.len]);
    var certificate_public_key: CertificatePublicKey = undefined;
    const public_key = key_pair.public_key.toUncompressedSec1();
    try certificate_public_key.init(.X9_62_id_ecPublicKey, &public_key);
    try certificate_public_key.verifySignature(
        tls_version,
        &signature_decoder,
        &.{ message[0..13], message[13..] },
    );
}

test "TLS ServerHello requires null compression" {
    // Validate the only compression method advertised by ClientHello and reject
    // a nonzero peer selection before version-specific state changes.
    try validateCompressionMethod(.null);
    try std.testing.expectError(
        error.TlsIllegalParameter,
        validateCompressionMethod(@enumFromInt(1)),
    );
}

test "TLS signature scheme gates reject legacy RSA in TLS 1.3" {
    // Exercise version gating directly so TLS 1.2 retains PKCS#1 while TLS 1.3
    // admits only handshake-safe PSS, ECDSA, and EdDSA schemes.
    try CertificatePublicKey.validateSignatureSchemeForVersion(
        .tls_1_2,
        .rsa_pkcs1_sha256,
    );
    try std.testing.expectError(
        error.TlsBadSignatureScheme,
        CertificatePublicKey.validateSignatureSchemeForVersion(
            .tls_1_3,
            .rsa_pkcs1_sha256,
        ),
    );
    try CertificatePublicKey.validateSignatureSchemeForVersion(
        .tls_1_3,
        .rsa_pss_rsae_sha256,
    );
}

test "TLS RSA signatures must exactly match the modulus byte count" {
    // Check both sides of the RSA-2048 boundary before fixed-array conversion
    // can observe an attacker-controlled signature length.
    try CertificatePublicKey.validateRSASignatureLength(
        &([_]u8{0} ** 256),
        256,
    );
    try std.testing.expectError(
        error.InvalidEncoding,
        CertificatePublicKey.validateRSASignatureLength(
            &([_]u8{0} ** 255),
            256,
        ),
    );
    try std.testing.expectError(
        error.InvalidEncoding,
        CertificatePublicKey.validateRSASignatureLength(
            &([_]u8{0} ** 257),
            256,
        ),
    );
}

test "TLS 1.2 ECDSA accepts P-384 with SHA-256" {
    // Sign deterministically with a P-384 key and SHA-256, then verify TLS 1.2
    // accepts the certificate curve while TLS 1.3 rejects the scheme mismatch.
    try verifyDeterministicECDSA(
        crypto.ecc.P384,
        crypto.hash.sha2.Sha256,
        .tls_1_2,
        .ecdsa_secp256r1_sha256,
        0x38,
    );
    try std.testing.expectError(
        error.TlsBadSignatureScheme,
        verifyDeterministicECDSA(
            crypto.ecc.P384,
            crypto.hash.sha2.Sha256,
            .tls_1_3,
            .ecdsa_secp256r1_sha256,
            0x38,
        ),
    );
}

test "TLS 1.2 ECDSA accepts P-256 with SHA-384" {
    // Sign deterministically with a P-256 key and SHA-384, then verify TLS 1.2
    // accepts the certificate curve while TLS 1.3 rejects the scheme mismatch.
    try verifyDeterministicECDSA(
        crypto.ecc.P256,
        crypto.hash.sha2.Sha384,
        .tls_1_2,
        .ecdsa_secp384r1_sha384,
        0x25,
    );
    try std.testing.expectError(
        error.TlsBadSignatureScheme,
        verifyDeterministicECDSA(
            crypto.ecc.P256,
            crypto.hash.sha2.Sha384,
            .tls_1_3,
            .ecdsa_secp384r1_sha384,
            0x25,
        ),
    );
}

test "TLS certificate verification accepts an Ed25519 public key" {
    // Sign a known transcript with a deterministic Ed25519 key, then drive the
    // CertificateVerify decoder through the advertised signature scheme.
    const Ed25519 = crypto.sign.Ed25519;
    const key_pair = try Ed25519.KeyPair.generateDeterministic(
        [_]u8{0x42} ** Ed25519.KeyPair.seed_length,
    );
    const message = "client-randomserver-randomtranscript";
    const signature = try key_pair.sign(message, null);
    const signature_bytes = signature.toBytes();
    var encoded: [4 + signature_bytes.len]u8 = undefined;
    mem.writeInt(
        u16,
        encoded[0..2],
        @intFromEnum(tls.SignatureScheme.ed25519),
        .big,
    );
    mem.writeInt(u16, encoded[2..4], signature_bytes.len, .big);
    @memcpy(encoded[4..], &signature_bytes);
    var signature_decoder = tls.Decoder.fromTheirSlice(&encoded);
    var certificate_public_key: CertificatePublicKey = undefined;
    try certificate_public_key.init(
        .curveEd25519,
        &key_pair.public_key.toBytes(),
    );
    try certificate_public_key.verifySignature(
        .tls_1_3,
        &signature_decoder,
        &.{ message[0..13], message[13..] },
    );
}

test "TLS init reassembles a cleartext ServerHello across records" {
    // Split before random bytes that resemble a Finished header so only reassembly can proceed.
    const testing = std.testing;
    const server_hello_body_length: u24 = 38;
    var server_hello: [4 + server_hello_body_length]u8 = undefined;
    server_hello[0] = @intFromEnum(tls.HandshakeType.server_hello);
    mem.writeInt(u24, server_hello[1..4], server_hello_body_length, .big);
    mem.writeInt(
        u16,
        server_hello[4..6],
        @intFromEnum(tls.ProtocolVersion.tls_1_2),
        .big,
    );
    @memset(server_hello[6..38], 0x44);
    server_hello[6..10].* = .{
        @intFromEnum(tls.HandshakeType.finished),
        0,
        0,
        0,
    };
    server_hello[38] = 0;
    mem.writeInt(
        u16,
        server_hello[39..41],
        @intFromEnum(tls.CipherSuite.ECDHE_RSA_WITH_AES_128_GCM_SHA256),
        .big,
    );
    server_hello[41] = @intFromEnum(tls.CompressionMethod.null);

    const first_fragment_length: u16 = 6;
    const second_fragment_length: u16 = server_hello.len - first_fragment_length;
    var input_bytes: [min_buffer_len]u8 = undefined;
    input_bytes[0] = @intFromEnum(tls.ContentType.handshake);
    mem.writeInt(
        u16,
        input_bytes[1..3],
        @intFromEnum(tls.ProtocolVersion.tls_1_2),
        .big,
    );
    mem.writeInt(u16, input_bytes[3..5], first_fragment_length, .big);
    @memcpy(input_bytes[5..][0..first_fragment_length], server_hello[0..first_fragment_length]);
    const second_record_offset = tls.record_header_len + first_fragment_length;
    input_bytes[second_record_offset] = @intFromEnum(tls.ContentType.handshake);
    mem.writeInt(
        u16,
        input_bytes[second_record_offset + 1 ..][0..2],
        @intFromEnum(tls.ProtocolVersion.tls_1_2),
        .big,
    );
    mem.writeInt(
        u16,
        input_bytes[second_record_offset + 3 ..][0..2],
        second_fragment_length,
        .big,
    );
    @memcpy(
        input_bytes[second_record_offset + tls.record_header_len ..][0..second_fragment_length],
        server_hello[first_fragment_length..],
    );
    const input_length = second_record_offset + tls.record_header_len + second_fragment_length;

    var input = Reader.fixed(&input_bytes);
    input.end = input_length;
    var encrypted: Writer.Allocating = .init(testing.allocator);
    defer encrypted.deinit();
    var read_buffer: [min_buffer_len]u8 = undefined;
    var write_buffer: [min_buffer_len]u8 = undefined;
    var client: Client = undefined;
    const entropy = [_]u8{1} ** Options.entropy_len;
    try testing.expectError(
        error.TLSConnectionTruncated,
        init(&client, &input, &encrypted.writer, .{
            .host = .no_verification,
            .server_name = null,
            .ca = .no_verification,
            .write_buffer = &write_buffer,
            .read_buffer = &read_buffer,
            .entropy = &entropy,
            .realtime_now = std.Io.Timestamp.now(testing.io, .real),
            .ssl_key_log = null,
            .alert = null,
        }),
    );
}

test "handshake fragments retain a partial message after a complete message" {
    // Recreate the cross-record layout that made a relative decoder index drop bytes.
    const testing = std.testing;
    var fragments: HandshakeFragments = .{};
    const first_record = [_]u8{
        @intFromEnum(tls.HandshakeType.server_hello),
        0,
        0,
        1,
        0xAA,
        @intFromEnum(tls.HandshakeType.certificate),
        0,
    };
    try fragments.append(&first_record);

    var decoder = fragments.decoder();
    try decoder.ensure(4);
    try testing.expectEqual(tls.HandshakeType.server_hello, decoder.decode(tls.HandshakeType));
    const first_body_length = decoder.decode(u24);
    const first_body = try decoder.sub(first_body_length);
    try testing.expectEqualSlices(u8, &.{0xAA}, first_body.buf);
    fragments.advanceConsumed(decoder.idx);

    try fragments.append(&.{ 0, 2, 0xBB, 0xCC });
    decoder = fragments.decoder();
    try testing.expectEqualSlices(
        u8,
        &.{
            @intFromEnum(tls.HandshakeType.certificate),
            0,
            0,
            2,
            0xBB,
            0xCC,
        },
        decoder.buf,
    );
    try decoder.ensure(4);
    try testing.expectEqual(tls.HandshakeType.certificate, decoder.decode(tls.HandshakeType));
    const second_body_length = decoder.decode(u24);
    const second_body = try decoder.sub(second_body_length);
    try testing.expectEqualSlices(u8, &.{ 0xBB, 0xCC }, second_body.buf);
    fragments.advanceConsumed(decoder.idx);
    fragments.reset();
    try testing.expect(fragments.decoder().eof());
}

test "handshake fragments compact consumed bytes and enforce their fixed capacity" {
    // Force the sole compaction path so retained bytes cannot be lost at the buffer boundary.
    const testing = std.testing;
    var fragments: HandshakeFragments = .{};
    const initial_byte_count = handshake_message_bytes_max - 4;
    const writable = try fragments.writable(initial_byte_count);
    @memset(writable, 0xAA);
    writable[initial_byte_count - 4 ..][0..4].* = .{ 1, 2, 3, 4 };
    fragments.commit(initial_byte_count);
    fragments.advanceConsumed(initial_byte_count - 4);

    try fragments.append(&.{ 5, 6, 7, 8, 9, 10, 11, 12 });
    const decoder = fragments.decoder();
    try testing.expectEqualSlices(
        u8,
        &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 },
        decoder.buf,
    );
    try testing.expectError(
        error.TlsRecordOverflow,
        fragments.writable(handshake_message_bytes_max),
    );
    fragments.advanceConsumed(decoder.buf.len);
    fragments.reset();
}

test "TLS compatibility CCS validates ensured input without panicking" {
    // Decode the exact middlebox-compatibility payload through the same helper
    // used by network handshakes, then reject malformed length and value inputs.
    var valid_decoder = tls.Decoder.fromTheirSlice(@constCast("\x01"));
    try consumeCompatibilityChangeCipherSpec(&valid_decoder, 1);

    var wrong_value_decoder = tls.Decoder.fromTheirSlice(@constCast("\x02"));
    try std.testing.expectError(
        error.TlsIllegalParameter,
        consumeCompatibilityChangeCipherSpec(&wrong_value_decoder, 1),
    );
    var wrong_length_decoder = tls.Decoder.fromTheirSlice(@constCast("\x01\x01"));
    try std.testing.expectError(
        error.TlsIllegalParameter,
        consumeCompatibilityChangeCipherSpec(&wrong_length_decoder, 2),
    );
}

test "TLS writer flush preserves a full minimum-sized plaintext buffer" {
    // Exercise the public Writer seam with the exact minimum buffer size, then
    // independently decrypt every emitted record to verify no plaintext is lost.
    const testing = std.testing;
    const plaintext_len = min_buffer_len;
    const record_count_max: u8 = 4;
    const key = [_]u8{0x22} ** 16;
    const iv = [_]u8{0x33} ** 12;

    var plaintext: [plaintext_len]u8 = undefined;
    for (&plaintext, 0..) |*byte, index| {
        byte.* = @truncate(index);
    }
    var encrypted = try std.Io.Writer.Allocating.initCapacity(
        testing.allocator,
        min_buffer_len,
    );
    defer encrypted.deinit();
    var write_buffer: [min_buffer_len]u8 = undefined;
    var client: Client = undefined;
    client.output = &encrypted.writer;
    client.writer = .{
        .buffer = &write_buffer,
        .vtable = &.{
            .drain = drain,
            .flush = flush,
        },
    };
    client.tls_version = .tls_1_3;
    client.write_sequence = 0;
    client.ssl_key_log = null;
    client.application_cipher = .{ .AES_128_GCM_SHA256 = .{
        .tls_1_3 = .{
            .client_secret = [_]u8{0x11} ** 32,
            .server_secret = [_]u8{0x44} ** 32,
            .client_key = key,
            .server_key = [_]u8{0x55} ** 16,
            .client_iv = iv,
            .server_iv = [_]u8{0x66} ** 12,
        },
    } };

    try client.writer.writeAll(&plaintext);
    try client.writer.flush();

    const records = encrypted.written();
    var decrypted: [plaintext_len]u8 = undefined;
    var decrypted_len: usize = 0;
    var record_offset: usize = 0;
    var sequence: u64 = 0;
    for (0..record_count_max) |_| {
        if (record_offset == records.len) break;
        try testing.expect(records.len - record_offset >= tls.record_header_len);
        const header = records[record_offset..][0..tls.record_header_len];
        try testing.expectEqual(
            @intFromEnum(tls.ContentType.application_data),
            header[0],
        );
        const payload_len = mem.readInt(u16, header[3..5], .big);
        const record_byte_count = tls.record_header_len + payload_len;
        try testing.expect(records.len - record_offset >= record_byte_count);
        const record = records[record_offset..][0..record_byte_count];
        const ciphertext_len = payload_len - crypto.aead.aes_gcm.Aes128Gcm.tag_length;
        var cleartext: [max_ciphertext_len]u8 = undefined;
        var nonce = iv;
        const nonce_tail = nonce[nonce.len - @sizeOf(u64) ..];
        mem.writeInt(
            u64,
            nonce_tail,
            mem.readInt(u64, nonce_tail, .big) ^ sequence,
            .big,
        );
        const tag_length = crypto.aead.aes_gcm.Aes128Gcm.tag_length;
        const tag_start = record.len - tag_length;
        const auth_tag = record[tag_start..][0..tag_length].*;
        try crypto.aead.aes_gcm.Aes128Gcm.decrypt(
            cleartext[0..ciphertext_len],
            record[tls.record_header_len..][0..ciphertext_len],
            auth_tag,
            header,
            nonce,
            key,
        );
        try testing.expectEqual(
            @intFromEnum(tls.ContentType.application_data),
            cleartext[ciphertext_len - 1],
        );
        const application_len = ciphertext_len - 1;
        try testing.expect(decrypted.len - decrypted_len >= application_len);
        @memcpy(
            decrypted[decrypted_len..][0..application_len],
            cleartext[0..application_len],
        );
        decrypted_len += application_len;
        record_offset += record_byte_count;
        sequence += 1;
    }
    try testing.expectEqual(records.len, record_offset);
    try testing.expectEqual(plaintext.len, decrypted_len);
    try testing.expectEqualSlices(u8, &plaintext, decrypted[0..decrypted_len]);
    try testing.expectEqual(@as(usize, 0), client.writer.buffered().len);
}

test "TLS writer bounds vector and splat drains without losing partial input" {
    // Invoke the Writer callback with one item beyond each fixed quota, then
    // decrypt every emitted record to verify the partial-consumption contract.
    const testing = std.testing;
    const key = [_]u8{0x22} ** 16;
    const iv = [_]u8{0x33} ** 12;
    const vectors = [_][]const u8{
        "1", "2", "3", "4", "5", "6", "7", "8", "9",
    };
    const expected_plaintext = "123456789zzzzzzzzz";
    const record_byte_count = tls.record_header_len + 2 +
        crypto.aead.aes_gcm.Aes128Gcm.tag_length;
    comptime {
        assert(vectors.len == writer_vector_count_max + 1);
        assert(expected_plaintext.len == vectors.len + writer_splat_count_max + 1);
    }

    var encrypted: Writer.Allocating = .init(testing.allocator);
    defer encrypted.deinit();
    var write_buffer: [min_buffer_len]u8 = undefined;
    var client: Client = undefined;
    client.output = &encrypted.writer;
    client.writer = .{
        .buffer = &write_buffer,
        .vtable = &.{
            .drain = drain,
            .flush = flush,
        },
    };
    client.tls_version = .tls_1_3;
    client.write_sequence = 0;
    client.ssl_key_log = null;
    client.application_cipher = .{ .AES_128_GCM_SHA256 = .{
        .tls_1_3 = .{
            .client_secret = [_]u8{0x11} ** 32,
            .server_secret = [_]u8{0x44} ** 32,
            .client_key = key,
            .server_key = [_]u8{0x55} ** 16,
            .client_iv = iv,
            .server_iv = [_]u8{0x66} ** 12,
        },
    } };

    try testing.expectEqual(
        @as(usize, writer_vector_count_max),
        try drain(&client.writer, &vectors, 1),
    );
    try testing.expectEqual(
        @as(usize, 1),
        try drain(&client.writer, vectors[writer_vector_count_max..], 1),
    );
    try testing.expectEqual(
        @as(usize, writer_splat_count_max),
        try drain(&client.writer, &.{"z"}, writer_splat_count_max + 1),
    );
    try testing.expectEqual(
        @as(usize, 1),
        try drain(&client.writer, &.{"z"}, 1),
    );

    const records = encrypted.written();
    try testing.expectEqual(
        expected_plaintext.len * record_byte_count,
        records.len,
    );
    for (0..expected_plaintext.len) |record_index| {
        const record_offset = record_index * record_byte_count;
        const record = records[record_offset..][0..record_byte_count];
        var nonce = iv;
        const nonce_tail = nonce[nonce.len - @sizeOf(u64) ..];
        mem.writeInt(
            u64,
            nonce_tail,
            mem.readInt(u64, nonce_tail, .big) ^ record_index,
            .big,
        );
        var cleartext: [2]u8 = undefined;
        const tag_length = crypto.aead.aes_gcm.Aes128Gcm.tag_length;
        try crypto.aead.aes_gcm.Aes128Gcm.decrypt(
            &cleartext,
            record[tls.record_header_len..][0..cleartext.len],
            record[record.len - tag_length ..][0..tag_length].*,
            record[0..tls.record_header_len],
            nonce,
            key,
        );
        try testing.expectEqual(expected_plaintext[record_index], cleartext[0]);
        try testing.expectEqual(
            @intFromEnum(tls.ContentType.application_data),
            cleartext[1],
        );
    }
}

test "TLS init rejects oversized cleartext records before alert parsing" {
    // Present a syntactically valid fatal-alert prefix in a 16385-byte
    // TLSPlaintext record and verify the plaintext limit wins before decoding.
    const testing = std.testing;
    const oversized_byte_count =
        tls.max_ciphertext_inner_record_len + 1;
    var input_bytes: [min_buffer_len]u8 = @splat(0);
    input_bytes[0] = @intFromEnum(tls.ContentType.alert);
    mem.writeInt(
        u16,
        input_bytes[1..3],
        @intFromEnum(tls.ProtocolVersion.tls_1_2),
        .big,
    );
    mem.writeInt(u16, input_bytes[3..5], oversized_byte_count, .big);
    input_bytes[5] = @intFromEnum(tls.Alert.Level.fatal);
    input_bytes[6] = @intFromEnum(tls.Alert.Description.handshake_failure);
    var input = Reader.fixed(&input_bytes);
    input.end = tls.record_header_len + oversized_byte_count;
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var read_buffer: [min_buffer_len]u8 = undefined;
    var write_buffer: [min_buffer_len]u8 = undefined;
    var client: Client = undefined;
    const entropy = [_]u8{1} ** Options.entropy_len;
    try testing.expectError(
        error.TlsRecordOverflow,
        init(&client, &input, &output.writer, .{
            .host = .no_verification,
            .server_name = null,
            .ca = .no_verification,
            .write_buffer = &write_buffer,
            .read_buffer = &read_buffer,
            .entropy = &entropy,
            .realtime_now = std.Io.Timestamp.now(testing.io, .real),
            .ssl_key_log = null,
            .alert = null,
        }),
    );
}

test "TLS init rejects a handshake that exceeds its record budget" {
    // Feed the public initializer one more complete record than the fixed
    // handshake budget and verify it rejects the excess before reading onward.
    const testing = std.testing;
    const record_count_limit_expected: u16 = 256;
    const record_byte_count: u8 = tls.record_header_len + 1;
    comptime {
        assert(record_count_limit_expected == handshake_record_count_max);
        assert((record_count_limit_expected + 1) * record_byte_count <=
            min_buffer_len);
    }
    var input_bytes = [_]u8{0} ** min_buffer_len;
    for (0..record_count_limit_expected + 1) |record_index| {
        const offset = record_index * record_byte_count;
        input_bytes[offset] = @intFromEnum(tls.ContentType.change_cipher_spec);
        mem.writeInt(
            u16,
            input_bytes[offset + 1 ..][0..2],
            @intFromEnum(tls.ProtocolVersion.tls_1_2),
            .big,
        );
        mem.writeInt(u16, input_bytes[offset + 3 ..][0..2], 1, .big);
        input_bytes[offset + tls.record_header_len] =
            @intFromEnum(tls.ChangeCipherSpecType.change_cipher_spec);
    }

    var input = std.Io.Reader.fixed(&input_bytes);
    var encrypted: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encrypted.deinit();
    var read_buffer: [min_buffer_len]u8 = undefined;
    var write_buffer: [min_buffer_len]u8 = undefined;
    var client: Client = undefined;
    const entropy = [_]u8{1} ** Options.entropy_len;
    var alert: tls.Alert = undefined;
    try testing.expectError(
        error.TlsHandshakeRecordLimitExceeded,
        init(&client, &input, &encrypted.writer, .{
            .host = .no_verification,
            .server_name = null,
            .ca = .no_verification,
            .write_buffer = &write_buffer,
            .read_buffer = &read_buffer,
            .entropy = &entropy,
            .realtime_now = std.Io.Timestamp.now(std.testing.io, .real),
            .ssl_key_log = null,
            .alert = &alert,
        }),
    );
}

test "TLS writer rejects an exhausted record sequence without consuming plaintext" {
    // Set the public Writer seam at the final sequence value and verify a write
    // fails before producing ciphertext or consuming the buffered plaintext.
    const testing = std.testing;
    var encrypted = try std.Io.Writer.Allocating.initCapacity(
        testing.allocator,
        min_buffer_len,
    );
    defer encrypted.deinit();
    var write_buffer: [min_buffer_len]u8 = undefined;
    var client: Client = undefined;
    client.output = &encrypted.writer;
    client.writer = .{
        .buffer = &write_buffer,
        .vtable = &.{
            .drain = drain,
            .flush = flush,
        },
    };
    client.tls_version = .tls_1_3;
    client.write_sequence = std.math.maxInt(u64);
    client.ssl_key_log = null;
    client.application_cipher = .{ .AES_128_GCM_SHA256 = .{
        .tls_1_3 = .{
            .client_secret = [_]u8{0x11} ** 32,
            .server_secret = [_]u8{0x44} ** 32,
            .client_key = [_]u8{0x22} ** 16,
            .server_key = [_]u8{0x55} ** 16,
            .client_iv = [_]u8{0x33} ** 12,
            .server_iv = [_]u8{0x66} ** 12,
        },
    } };

    try client.writer.writeByte(0xA5);
    try testing.expectError(error.WriteFailed, client.writer.flush());
    try testing.expectEqual(std.math.maxInt(u64), client.write_sequence);
    try testing.expectEqual(error.TLSSequenceOverflow, client.write_error.?);
    try testing.expectEqual(@as(usize, 1), client.writer.buffered().len);
    try testing.expectEqual(@as(usize, 0), encrypted.written().len);
}

test "TLS writer keeps sequence state atomic when a later record overflows" {
    // Start one sequence before exhaustion and flush enough plaintext for two
    // records, then verify the failed batch commits neither sequence nor bytes.
    const testing = std.testing;
    var encrypted = try std.Io.Writer.Allocating.initCapacity(
        testing.allocator,
        min_buffer_len,
    );
    defer encrypted.deinit();
    var write_buffer: [min_buffer_len]u8 = undefined;
    var client: Client = undefined;
    client.output = &encrypted.writer;
    client.writer = .{
        .buffer = &write_buffer,
        .vtable = &.{
            .drain = drain,
            .flush = flush,
        },
    };
    client.tls_version = .tls_1_3;
    client.write_sequence = std.math.maxInt(u64) - 1;
    client.write_error = null;
    client.ssl_key_log = null;
    client.application_cipher = .{ .AES_128_GCM_SHA256 = .{
        .tls_1_3 = .{
            .client_secret = [_]u8{0x11} ** 32,
            .server_secret = [_]u8{0x44} ** 32,
            .client_key = [_]u8{0x22} ** 16,
            .server_key = [_]u8{0x55} ** 16,
            .client_iv = [_]u8{0x33} ** 12,
            .server_iv = [_]u8{0x66} ** 12,
        },
    } };
    const plaintext = [_]u8{0xA5} ** min_buffer_len;

    try client.writer.writeAll(&plaintext);
    try testing.expectError(error.WriteFailed, client.writer.flush());
    try testing.expectEqual(std.math.maxInt(u64) - 1, client.write_sequence);
    try testing.expectEqual(error.TLSSequenceOverflow, client.write_error.?);
    try testing.expectEqual(plaintext.len, client.writer.buffered().len);
    try testing.expectEqual(@as(usize, 0), encrypted.written().len);
}

test "post-handshake KeyUpdate reassembles records and rejects malformed input" {
    // Feed focused TLS records through the client seam and inspect records, errors, and key state.
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var write_buffer: [min_buffer_len]u8 = undefined;
    var client: Client = undefined;
    client.output = &output.writer;
    client.writer = .{
        .buffer = &write_buffer,
        .vtable = &.{
            .drain = drain,
            .flush = flush,
        },
    };
    client.read_error = null;
    client.tls_version = .tls_1_3;
    client.read_sequence = 9;
    client.write_sequence = 7;
    client.post_handshake = .{};
    client.ssl_key_log = null;
    client.application_cipher = .{ .AES_128_GCM_SHA256 = .{
        .tls_1_3 = .{
            .client_secret = [_]u8{0x11} ** 32,
            .server_secret = [_]u8{0x44} ** 32,
            .client_key = [_]u8{0x22} ** 16,
            .server_key = [_]u8{0x55} ** 16,
            .client_iv = [_]u8{0x33} ** 12,
            .server_iv = [_]u8{0x66} ** 12,
        },
    } };

    try std.testing.expectEqual(
        @as(usize, 0),
        try processPostHandshake(&client, "\x18"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try processPostHandshake(&client, "\x00\x00\x01"),
    );
    try std.testing.expectEqual(@as(u64, 9), client.read_sequence);
    try std.testing.expectEqual(
        @as(usize, 0),
        try processPostHandshake(&client, "\x01"),
    );
    try std.testing.expectEqual(@as(u64, 0), client.read_sequence);
    try std.testing.expectEqual(@as(u64, 0), client.write_sequence);
    try std.testing.expectEqual(@as(usize, 27), output.written().len);

    client.post_handshake = .{};
    client.read_error = null;
    try std.testing.expectError(
        error.ReadFailed,
        processPostHandshake(&client, "\x18\x00\x00\x00"),
    );
    try std.testing.expectEqual(
        error.TlsBadLength,
        client.read_error.?,
    );

    client.post_handshake = .{};
    client.read_error = null;
    try std.testing.expectError(
        error.ReadFailed,
        processPostHandshake(
            &client,
            "\x18\x00\x00\x01\x00\x04",
        ),
    );
    try std.testing.expectEqual(
        error.TlsUnexpectedMessage,
        client.read_error.?,
    );

    client.post_handshake = .{};
    client.read_error = null;
    client.tls_version = .tls_1_2;
    try std.testing.expectError(
        error.ReadFailed,
        processPostHandshake(&client, "\x18\x00\x00\x01\x00"),
    );
    try std.testing.expectEqual(
        error.TlsUnexpectedMessage,
        client.read_error.?,
    );
}

test "one-record read distinguishes application and standalone TLS control records" {
    // Encrypt one application record and one KeyUpdate record independently,
    // then verify the public record seam buffers data but returns controls.
    const allocator = std.testing.allocator;
    const server_key = [_]u8{0x55} ** 16;
    const server_iv = [_]u8{0x66} ** 12;
    const cleartext = [_]u8{
        @intFromEnum(tls.HandshakeType.key_update),
        0,
        0,
        1,
        @intFromEnum(tls.KeyUpdateRequest.update_not_requested),
        @intFromEnum(tls.ContentType.handshake),
    };
    var record: [
        tls.record_header_len + cleartext.len +
            crypto.aead.aes_gcm.Aes128Gcm.tag_length
    ]u8 = undefined;
    record[0] = @intFromEnum(tls.ContentType.application_data);
    mem.writeInt(
        u16,
        record[1..3],
        @intFromEnum(tls.ProtocolVersion.tls_1_2),
        .big,
    );
    mem.writeInt(
        u16,
        record[3..5],
        cleartext.len + crypto.aead.aes_gcm.Aes128Gcm.tag_length,
        .big,
    );
    crypto.aead.aes_gcm.Aes128Gcm.encrypt(
        record[5 .. 5 + cleartext.len],
        record[5 + cleartext.len ..][0..crypto.aead.aes_gcm.Aes128Gcm.tag_length],
        &cleartext,
        record[0..5],
        server_iv,
        server_key,
    );

    const application_cleartext = [_]u8{
        'o',
        'k',
        @intFromEnum(tls.ContentType.application_data),
    };
    var application_record: [
        tls.record_header_len + application_cleartext.len +
            crypto.aead.aes_gcm.Aes128Gcm.tag_length
    ]u8 = undefined;
    application_record[0] = @intFromEnum(tls.ContentType.application_data);
    mem.writeInt(
        u16,
        application_record[1..3],
        @intFromEnum(tls.ProtocolVersion.tls_1_2),
        .big,
    );
    mem.writeInt(
        u16,
        application_record[3..5],
        application_cleartext.len + crypto.aead.aes_gcm.Aes128Gcm.tag_length,
        .big,
    );
    const application_tag_offset = 5 + application_cleartext.len;
    const application_tag_len = crypto.aead.aes_gcm.Aes128Gcm.tag_length;
    const application_tag = application_record[application_tag_offset..][0..application_tag_len];
    crypto.aead.aes_gcm.Aes128Gcm.encrypt(
        application_record[5 .. 5 + application_cleartext.len],
        application_tag,
        &application_cleartext,
        application_record[0..5],
        server_iv,
        server_key,
    );

    var input = std.Io.Reader.fixed(&record);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var read_buffer: [min_buffer_len]u8 = undefined;
    var write_buffer: [min_buffer_len]u8 = undefined;
    var client: Client = .{
        .input = &input,
        .reader = .{
            .buffer = &read_buffer,
            .vtable = &.{
                .stream = stream,
                .readVec = readVec,
            },
            .seek = 0,
            .end = 0,
        },
        .output = &output.writer,
        .writer = .{
            .buffer = &write_buffer,
            .vtable = &.{
                .drain = drain,
                .flush = flush,
            },
        },
        .tls_version = .tls_1_3,
        .read_sequence = 0,
        .write_sequence = 0,
        .received_close_notify = false,
        .application_cipher = .{ .AES_128_GCM_SHA256 = .{
            .tls_1_3 = .{
                .client_secret = [_]u8{0x11} ** 32,
                .server_secret = [_]u8{0x44} ** 32,
                .client_key = [_]u8{0x22} ** 16,
                .server_key = server_key,
                .client_iv = [_]u8{0x33} ** 12,
                .server_iv = server_iv,
            },
        } },
        .ssl_key_log = null,
    };

    var application_input = std.Io.Reader.fixed(&application_record);
    client.input = &application_input;
    try std.testing.expectEqual(
        RecordEvent.application_data,
        try client.readOneRecord(),
    );
    try std.testing.expectEqualStrings("ok", client.reader.buffered());
    client.reader.seek = client.reader.end;
    client.read_sequence = 0;
    client.input = &input;

    try std.testing.expectEqual(
        RecordEvent.control,
        try client.readOneRecord(),
    );
    try std.testing.expectEqual(@as(usize, 0), client.reader.bufferedLen());

    var short_input = std.Io.Reader.fixed("\x17\x03\x03\x00\x00");
    client.input = &short_input;
    client.read_error = null;
    try std.testing.expectError(error.ReadFailed, client.readOneRecord());
    try std.testing.expectEqual(error.TlsDecodeError, client.read_error.?);

    var boundary_eof_input = Reader.fixed("");
    client.input = &boundary_eof_input;
    client.read_error = null;
    try std.testing.expectError(error.ReadFailed, client.readOneRecord());
    try std.testing.expectEqual(
        error.TLSConnectionTruncated,
        client.read_error.?,
    );
}

test "TLS 1.2 alert parser preserves split and coalesced alert messages" {
    // Feed one-byte fragments and two coalesced alerts through the bounded
    // parser to verify exact pair boundaries across record payloads.
    var parser: AlertParser = .{};
    var first_byte_index: usize = 0;
    try std.testing.expect(parser.next("\x02", &first_byte_index) == null);
    try std.testing.expectEqual(@as(usize, 1), first_byte_index);
    try std.testing.expect(!parser.isIdle());

    var remaining_byte_index: usize = 0;
    const split_alert = parser.next("\x28", &remaining_byte_index).?;
    try std.testing.expectEqual(tls.Alert.Level.fatal, split_alert.level);
    try std.testing.expectEqual(
        tls.Alert.Description.handshake_failure,
        split_alert.description,
    );
    try std.testing.expect(parser.isIdle());

    const coalesced = "\x01\x5a\x01\x00";
    var coalesced_byte_index: usize = 0;
    const user_canceled = parser.next(
        coalesced,
        &coalesced_byte_index,
    ).?;
    const close_notify = parser.next(
        coalesced,
        &coalesced_byte_index,
    ).?;
    try std.testing.expectEqual(
        tls.Alert.Description.user_canceled,
        user_canceled.description,
    );
    try std.testing.expectEqual(
        tls.Alert.Description.close_notify,
        close_notify.description,
    );
    try std.testing.expectEqual(coalesced.len, coalesced_byte_index);
}

test "TLS user_canceled waits for close_notify and rejects direct EOF" {
    // Encrypt warning alerts with consecutive record sequences, then verify
    // user_canceled is control-only while EOF without close_notify truncates.
    const testing = std.testing;
    const server_key = [_]u8{0x55} ** 16;
    const server_iv = [_]u8{0x66} ** 12;
    const AlertRecord = struct {
        const cleartext_byte_count = 3;
        const record_byte_count = tls.record_header_len +
            cleartext_byte_count + crypto.aead.aes_gcm.Aes128Gcm.tag_length;

        fn encrypt(
            output: *[record_byte_count]u8,
            level: tls.Alert.Level,
            description: tls.Alert.Description,
            sequence: u64,
            key: [16]u8,
            iv: [12]u8,
        ) void {
            output[0] = @intFromEnum(tls.ContentType.application_data);
            mem.writeInt(
                u16,
                output[1..3],
                @intFromEnum(tls.ProtocolVersion.tls_1_2),
                .big,
            );
            const payload_byte_count = cleartext_byte_count +
                crypto.aead.aes_gcm.Aes128Gcm.tag_length;
            mem.writeInt(u16, output[3..5], payload_byte_count, .big);
            const cleartext = [_]u8{
                @intFromEnum(level),
                @intFromEnum(description),
                @intFromEnum(tls.ContentType.alert),
            };
            var nonce = iv;
            const nonce_tail = nonce[nonce.len - @sizeOf(u64) ..];
            mem.writeInt(
                u64,
                nonce_tail,
                mem.readInt(u64, nonce_tail, .big) ^ sequence,
                .big,
            );
            const tag_start = tls.record_header_len + cleartext.len;
            crypto.aead.aes_gcm.Aes128Gcm.encrypt(
                output[tls.record_header_len..tag_start],
                output[tag_start..][0..crypto.aead.aes_gcm.Aes128Gcm.tag_length],
                &cleartext,
                output[0..tls.record_header_len],
                nonce,
                key,
            );
        }
    };

    var user_canceled_record: [AlertRecord.record_byte_count]u8 = undefined;
    AlertRecord.encrypt(
        &user_canceled_record,
        .warning,
        .user_canceled,
        0,
        server_key,
        server_iv,
    );
    var close_notify_record: [AlertRecord.record_byte_count]u8 = undefined;
    AlertRecord.encrypt(
        &close_notify_record,
        .warning,
        .close_notify,
        1,
        server_key,
        server_iv,
    );
    const combined_records = user_canceled_record ++ close_notify_record;
    var input = Reader.fixed(&combined_records);
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var read_buffer: [min_buffer_len]u8 = undefined;
    var write_buffer: [min_buffer_len]u8 = undefined;
    var client: Client = .{
        .input = &input,
        .reader = .{
            .buffer = &read_buffer,
            .vtable = &.{
                .stream = stream,
                .readVec = readVec,
            },
            .seek = 0,
            .end = 0,
        },
        .output = &output.writer,
        .writer = .{
            .buffer = &write_buffer,
            .vtable = &.{
                .drain = drain,
                .flush = flush,
            },
        },
        .tls_version = .tls_1_3,
        .read_sequence = 0,
        .write_sequence = 0,
        .received_close_notify = false,
        .received_user_canceled = false,
        .application_cipher = .{ .AES_128_GCM_SHA256 = .{
            .tls_1_3 = .{
                .client_secret = [_]u8{0x11} ** 32,
                .server_secret = [_]u8{0x44} ** 32,
                .client_key = [_]u8{0x22} ** 16,
                .server_key = server_key,
                .client_iv = [_]u8{0x33} ** 12,
                .server_iv = server_iv,
            },
        } },
        .ssl_key_log = null,
    };

    try testing.expectEqual(RecordEvent.control, try client.readOneRecord());
    try testing.expectEqual(RecordEvent.eof, try client.readOneRecord());

    var truncated_input = Reader.fixed(&user_canceled_record);
    client.input = &truncated_input;
    client.reader.seek = 0;
    client.reader.end = 0;
    client.read_sequence = 0;
    client.read_error = null;
    client.received_close_notify = false;
    client.received_user_canceled = false;
    try testing.expectEqual(RecordEvent.control, try client.readOneRecord());
    try testing.expectError(error.ReadFailed, client.readOneRecord());
    try testing.expectEqual(error.TLSConnectionTruncated, client.read_error.?);

    var fatal_user_canceled_record: [AlertRecord.record_byte_count]u8 =
        undefined;
    AlertRecord.encrypt(
        &fatal_user_canceled_record,
        .fatal,
        .user_canceled,
        0,
        server_key,
        server_iv,
    );
    var fatal_user_canceled_input = Reader.fixed(
        &fatal_user_canceled_record,
    );
    client.input = &fatal_user_canceled_input;
    client.reader.seek = 0;
    client.reader.end = 0;
    client.read_sequence = 0;
    client.read_error = null;
    client.received_close_notify = false;
    client.received_user_canceled = false;
    try testing.expectEqual(RecordEvent.control, try client.readOneRecord());
}

test "TLS key log counters reject overflow without mutation" {
    // Place both counters at the u64 boundary and verify checked progression
    // reports overflow without changing either diagnostic sequence.
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var key_log: SSLKeyLog = .{
        .client_key_sequence = std.math.maxInt(u64),
        .server_key_sequence = std.math.maxInt(u64),
        .client_random = [_]u8{0} ** 32,
        .writer = &output.writer,
    };
    try std.testing.expectError(
        error.TLSSequenceOverflow,
        key_log.clientCounter(),
    );
    try std.testing.expectError(
        error.TLSSequenceOverflow,
        key_log.serverCounter(),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        key_log.client_key_sequence,
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        key_log.server_key_sequence,
    );
}

test "requested TLS 1.3 key update sends response before rotating write key" {
    // Decrypt the response with the old key, verify rotation order, and ensure
    // an enabled key log turns its write failure into an operation failure.
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var write_buffer: [min_buffer_len]u8 = undefined;

    const old_secret = [_]u8{0x11} ** 32;
    const old_key = [_]u8{0x22} ** 16;
    const old_iv = [_]u8{0x33} ** 12;
    const old_sequence: u64 = 7;
    var client: Client = undefined;
    client.output = &output.writer;
    client.writer = .{
        .buffer = &write_buffer,
        .vtable = &.{
            .drain = drain,
            .flush = flush,
        },
    };
    client.tls_version = .tls_1_3;
    client.write_sequence = old_sequence;
    client.ssl_key_log = null;
    client.application_cipher = .{ .AES_128_GCM_SHA256 = .{
        .tls_1_3 = .{
            .client_secret = old_secret,
            .server_secret = [_]u8{0x44} ** 32,
            .client_key = old_key,
            .server_key = [_]u8{0x55} ** 16,
            .client_iv = old_iv,
            .server_iv = [_]u8{0x66} ** 12,
        },
    } };

    try handleRequestedKeyUpdate(&client);

    const record = output.written();
    try std.testing.expectEqual(@as(usize, 27), record.len);
    try std.testing.expectEqual(
        @intFromEnum(tls.ContentType.application_data),
        record[0],
    );
    try std.testing.expectEqual(
        @as(u16, 22),
        std.mem.readInt(u16, record[3..5], .big),
    );

    var nonce = old_iv;
    const operand = std.mem.readInt(u64, nonce[nonce.len - 8 ..], .big);
    std.mem.writeInt(
        u64,
        nonce[nonce.len - 8 ..],
        operand ^ old_sequence,
        .big,
    );
    var cleartext: [6]u8 = undefined;
    try crypto.aead.aes_gcm.Aes128Gcm.decrypt(
        &cleartext,
        record[5..11],
        record[11..27].*,
        record[0..5],
        nonce,
        old_key,
    );
    try std.testing.expectEqualSlices(u8, &.{
        @intFromEnum(tls.HandshakeType.key_update),
        0,
        0,
        1,
        @intFromEnum(tls.KeyUpdateRequest.update_not_requested),
        @intFromEnum(tls.ContentType.handshake),
    }, &cleartext);
    try std.testing.expectEqual(@as(u64, 0), client.write_sequence);
    try std.testing.expect(!std.mem.eql(
        u8,
        &old_secret,
        &client.application_cipher.AES_128_GCM_SHA256.tls_1_3.client_secret,
    ));

    var failing_writer = Writer.failing;
    var key_log: SSLKeyLog = .{
        .client_key_sequence = 0,
        .server_key_sequence = 0,
        .client_random = [_]u8{0x77} ** 32,
        .writer = &failing_writer,
    };
    client.ssl_key_log = &key_log;
    try std.testing.expectError(
        error.WriteFailed,
        handleRequestedKeyUpdate(&client),
    );
}
