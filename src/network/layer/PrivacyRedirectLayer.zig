// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const builtin = @import("builtin");
const lp = @import("lightpanda");
const log = lp.log;

const IS_DEBUG = builtin.mode == .Debug;

const URL = @import("../../browser/URL.zig");
const http = @import("../http.zig");
const Config = @import("../../Config.zig");
const HttpClient = @import("../../browser/HttpClient.zig");
const Request = @import("../../browser/HttpClient.zig").Request;
const Transfer = @import("../../browser/HttpClient.zig").Transfer;
const Response = @import("../../browser/HttpClient.zig").Response;
const FulfilledResponse = @import("../../browser/HttpClient.zig").FulfilledResponse;
const Layer = @import("../../browser/HttpClient.zig").Layer;
const Forward = @import("Forward.zig");
const HeaderResult = @import("../../browser/HttpClient.zig").HeaderResult;

const PrivacyRedirectLayer = @This();

config: *const Config,

next: Layer = undefined,

pub fn layer(self: *PrivacyRedirectLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{ .request = request },
    };
}

fn parseRedirectRules(allocator: std.mem.Allocator, redirect_rules: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    var map = std.StringHashMapUnmanaged([]const u8).empty;
    errdefer map.deinit(allocator);

    // Format: <old-domain>=<new-domain>;<old-domain2>=<new-domain2>
    // Domains may optionally include a port (host:port) in either side
    var it = std.mem.splitScalar(u8, redirect_rules, ';');
    while (it.next()) |rule| {
        const trimmed = std.mem.trim(u8, rule, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        var eq_it = std.mem.splitScalar(u8, trimmed, '=');
        const old_domain = std.mem.trim(u8, eq_it.next() orelse continue, &std.ascii.whitespace);
        const new_domain = std.mem.trim(u8, eq_it.next() orelse continue, &std.ascii.whitespace);

        if (old_domain.len == 0 or new_domain.len == 0) continue;

        try map.put(allocator, old_domain, new_domain);
    }

    return map;
}

fn request(ptr: *anyopaque, transfer: *Transfer) anyerror!void {
    const self: *PrivacyRedirectLayer = @ptrCast(@alignCast(ptr));
    const req = &transfer.req;

    const redirect_rules_raw = self.config.redirectRules();
    const hostname = URL.getHostname(req.url);

    if (redirect_rules_raw) |rules| {
        var map = try parseRedirectRules(transfer.arena, rules);
        defer map.deinit(transfer.arena);

        if (map.get(hostname)) |new_domain| {
            req.url = try URL.setHostname(req.url, new_domain, transfer.arena);
            log.info(.http, "privacy redirect", .{ .url = req.url });
        }
    }

    return self.next.request(transfer);
}
