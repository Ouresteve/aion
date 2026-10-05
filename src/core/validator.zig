//! Stake-weighted validator membership and quorum calculations.

const std = @import("std");
const types = @import("types.zig");

pub const Validator = struct {
    address: types.Address,
    stake: types.MicroAion,
};

pub const ValidatorSet = struct {
    allocator: std.mem.Allocator,
    validators: []Validator,
    total_stake: types.MicroAion,

    pub fn init(allocator: std.mem.Allocator, validators: []const Validator) !ValidatorSet {
        if (validators.len == 0) return error.EmptyValidatorSet;

        const owned = try allocator.dupe(Validator, validators);
        errdefer allocator.free(owned);
        var total: types.MicroAion = 0;
        for (owned, 0..) |validator, index| {
            if (validator.stake == 0) return error.ZeroStake;
            for (owned[0..index]) |previous| {
                if (std.mem.eql(u8, &previous.address, &validator.address)) {
                    return error.DuplicateValidator;
                }
            }
            total = std.math.add(types.MicroAion, total, validator.stake) catch return error.StakeOverflow;
        }

        return .{
            .allocator = allocator,
            .validators = owned,
            .total_stake = total,
        };
    }

    pub fn deinit(self: *ValidatorSet) void {
        self.allocator.free(self.validators);
    }

    pub fn quorumStake(self: ValidatorSet) types.MicroAion {
        return self.total_stake - self.total_stake / 3;
    }

    pub fn hasQuorum(self: ValidatorSet, stake: types.MicroAion) bool {
        return stake >= self.quorumStake();
    }

    pub fn find(self: ValidatorSet, address: types.Address) ?Validator {
        for (self.validators) |validator| {
            if (std.mem.eql(u8, &validator.address, &address)) return validator;
        }
        return null;
    }

    pub fn leader(self: ValidatorSet, height: u64, round: u64) Validator {
        const index = @as(usize, @intCast((height % self.validators.len + round % self.validators.len) % self.validators.len));
        return self.validators[index];
    }
};

test "validator quorum requires more than two thirds of stake" {
    const allocator = std.testing.allocator;
    var set = try ValidatorSet.init(allocator, &.{
        .{ .address = @splat(1), .stake = 50 },
        .{ .address = @splat(2), .stake = 30 },
        .{ .address = @splat(3), .stake = 20 },
    });
    defer set.deinit();

    try std.testing.expectEqual(@as(u128, 67), set.quorumStake());
    try std.testing.expect(!set.hasQuorum(66));
    try std.testing.expect(set.hasQuorum(67));
}
