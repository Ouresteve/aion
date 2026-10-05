//! Settlement Transaction – the fundamental unit of value transfer in Aion.

const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");

pub const SettlementTx = struct {
    from: types.Address,
    to: types.Address,
    amount: types.MicroAion,
    nonce: types.Nonce,
    signature: crypto.Signature = undefined,

    /// Create the canonical fixed-width payload authenticated by the signature.
    pub fn messageToSign(self: SettlementTx) [88]u8 {
        var buf: [88]u8 = undefined;
        @memcpy(buf[0..32], &self.from);
        @memcpy(buf[32..64], &self.to);
        std.mem.writeInt(u128, buf[64..80], self.amount, .little);
        std.mem.writeInt(u64, buf[80..88], self.nonce, .little);
        return buf;
    }

    pub fn hash(self: SettlementTx) types.Hash {
        const message = self.messageToSign();
        const signature_bytes = crypto.signatureBytes(self.signature);
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&message);
        hasher.update(&signature_bytes);
        var digest: types.Hash = undefined;
        hasher.final(&digest);
        return digest;
    }

    /// Sign the transaction with the sender's secret key
    pub fn sign(self: *SettlementTx, key_pair: crypto.KeyPair) !void {
        const msg = self.messageToSign();
        self.signature = try crypto.sign(key_pair, &msg);
    }

    /// Verify the signature using the public key that matches `from`
    pub fn verify(self: SettlementTx) bool {
        const msg = self.messageToSign();
        // Reconstruct public key from the `from` address
        const public_key = crypto.PublicKey{ .bytes = self.from };
        return crypto.verify(public_key, &msg, self.signature);
    }

    /// Basic validation that does not require state
    pub fn validateBasic(self: SettlementTx) !void {
        if (self.amount == 0) {
            return error.ZeroAmount;
        }
        if (std.mem.eql(u8, &self.from, &self.to)) {
            return error.SelfTransfer;
        }
    }
};

test "transaction signature authenticates nonce" {
    const key_pair = try crypto.KeyPair.generateDeterministic(@splat(0x42));
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
}
