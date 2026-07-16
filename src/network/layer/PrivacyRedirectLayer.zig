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
const HttpClient = @import("../../browser/HttpClient.zig");
const Request = @import("../../browser/HttpClient.zig").Request;
const Transfer = @import("../../browser/HttpClient.zig").Transfer;
const Response = @import("../../browser/HttpClient.zig").Response;
const FulfilledResponse = @import("../../browser/HttpClient.zig").FulfilledResponse;
const Layer = @import("../../browser/HttpClient.zig").Layer;
const Forward = @import("Forward.zig");
const HeaderResult = @import("../../browser/HttpClient.zig").HeaderResult;

const PrivacyRedirectLayer = @This();

next: Layer = undefined,

pub fn layer(self: *PrivacyRedirectLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{ .request = request },
    };
}

fn request(ptr: *anyopaque, transfer: *Transfer) anyerror!void {
    const self: *PrivacyRedirectLayer = @ptrCast(@alignCast(ptr));
    const req = &transfer.req;

    const hostname = URL.getHostname(req.url);

    if (std.mem.eql(u8, hostname, "x.com") or std.mem.eql(u8, hostname, "twitter.com")) {
        req.url = try URL.setHostname(req.url, "xcancel.com", transfer.arena);
        log.info(.http, "WIP privacy redirect", .{ .url = req.url });
    }

    return self.next.request(transfer);
}
