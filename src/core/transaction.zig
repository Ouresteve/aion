//! Settlement Transaction – the fundamental unit of value transfer in Aion.
//!
//! Binary layout (version 1), little-endian, fixed size:
//!
//!   offset  size  field
//!   0       1     version          (currently 1)
//!   1       32    from             (Address)
//!   33      32    to               (Address)
//!   65      16    amount           (MicroAion / u128)
//!   81      8     nonce            (u64)
//!   89      64    signature        (Ed25519)
//!   --------------------------------
//!   Total   153 bytes
//!
//! The signature covers bytes [0 .. 89) (everything except the signature itself).

const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");

pub const TX_VERSION: u8 = 1;
pub const TX_SIZE: usize = 153;
pub const TX_SIGNED_PREFIX_SIZE: usize = 89; // version + from + to + amount + nonce

pub const SettlementTx = struct {
    version: u8 = TX_VERSION,
    from: types.Address,
    to: types.Address,
    amount: types.MicroAion,
    nonce: types.Nonce,
    signature: crypto.Signature = undefined,

    /// Canonical bytes that are signed (excludes signature).
    pub fn messageToSign(self: SettlementTx) [TX_SIGNED_PREFIX_SIZE]u8 {
        var buf: [TX_SIGNED_PREFIX_SIZE]u8 = undefined;
        self.writeSignedPrefix(&buf);
        return buf;
    }

    fn writeSignedPrefix(self: SettlementTx, output: *[TX_SIGNED_PREFIX_SIZE]u8) void {
        output[0] = self.version;
        @memcpy(output[1..33], &self.from);
        @memcpy(output[33..65], &self.to);
        std.mem.writeInt(u128, output[65..81], self.amount, .little);
        std.mem.writeInt(u64, output[81..89], self.nonce, .little);
    }

    /// Full fixed-size binary encoding (includes signature).
    pub fn encode(self: SettlementTx, output: *[TX_SIZE]u8) void {
        self.writeSignedPrefix(output[0..TX_SIGNED_PREFIX_SIZE]);
        const signature_bytes = crypto.signatureBytes(self.signature);
        @memcpy(output[TX_SIGNED_PREFIX_SIZE..TX_SIZE], &signature_bytes);
    }

    /// Decode from fixed-size binary. Does not verify the signature.
    pub fn decode(input: *const [TX_SIZE]u8) SettlementTx {
        var signature_bytes: [crypto.signature_length]u8 = undefined;
        @memcpy(&signature_bytes, input[TX_SIGNED_PREFIX_SIZE..TX_SIZE]);
        return .{
            .version = input[0],
            .from = input[1..33].*,
            .to = input[33..65].*,
            .amount = std.mem.readInt(u128, input[65..81], .little),
            .nonce = std.mem.readInt(u64, input[81..89], .little),
            .signature = crypto.signatureFromBytes(signature_bytes),
        };
    }

    /// Transaction ID = SHA-256(full encoded bytes).
    pub fn hash(self: SettlementTx) types.Hash {
        var encoded: [TX_SIZE]u8 = undefined;
        self.encode(&encoded);
        return crypto.hash(&encoded);
    }

    pub fn sign(self: *SettlementTx, key_pair: crypto.KeyPair) !void {
        const msg = self.messageToSign();
        self.signature = try crypto.sign(key_pair, &msg);
    }

    pub fn verify(self: SettlementTx) bool {
        if (self.version != TX_VERSION) return false;
        const msg = self.messageToSign();
        const public_key = crypto.publicKeyFromAddress(self.from);
        return crypto.verify(public_key, &msg, self.signature);
    }

    pub fn validateBasic(self: SettlementTx) !void {
        if (self.version != TX_VERSION) return error.UnsupportedTxVersion;
        if (self.amount == 0) return error.ZeroAmount;
        if (std.mem.eql(u8, &self.from, &self.to)) return error.SelfTransfer;
    }
};

test "transaction encode/decode round-trip" {
    const key_pair = try crypto.generateKeyPairDeterministic(@splat(0x42));
    const address = crypto.addressFromPublicKey(key_pair.public_key);

    var tx = SettlementTx{
        .from = address,
        .to = types.ZERO_ADDRESS,
        .amount = 1_000_000,
        .nonce = 7,
    };
    try tx.sign(key_pair);

    var buf: [TX_SIZE]u8 = undefined;
    tx.encode(&buf);
    const decoded = SettlementTx.decode(&buf);

    try std.testing.expect(decoded.version == TX_VERSION);
    try std.testing.expectEqualSlices(u8, &tx.from, &decoded.from);
    try std.testing.expectEqualSlices(u8, &tx.to, &decoded.to);
    try std.testing.expect(decoded.amount == tx.amount);
    try std.testing.expect(decoded.nonce == tx.nonce);
    try std.testing.expect(decoded.verify());
}

test "transaction signature authenticates nonce and version" {
    const key_pair = try crypto.generateKeyPairDeterministic(@splat(0x42));
    const address = crypto.addressFromPublicKey(key_pair.public_key);

    var tx = SettlementTx{
        .from = address,
        .to = types.ZERO_ADDRESS,
        .amount = 1,
        .nonce = 0,
    };
    try tx.sign(key_pair);
    try std.testing.expect(tx.verify());

    tx.nonce = 1;
    try std.testing.expect(!tx.verify());

    tx.nonce = 0;
    tx.version = 2;
    try std.testing.expect(!tx.verify());
}
