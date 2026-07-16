// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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
const json = std.json;
const SemanticVersion = std.SemanticVersion;
const Allocator = std.mem.Allocator;
const lp = @import("lightpanda");

const Network = @import("network/Network.zig");
const http = @import("network/http.zig");
const libcurl = @import("sys/libcurl.zig");
const crypto = @import("sys/libcrypto.zig");
const Config = @import("Config.zig");
const log = @import("log.zig");

/// Sole purpose of this client is to do updates; hence, its very minimal.
const Updater = @This();
x509_store: *crypto.X509_STORE,
config: *const Config,

/// Initializes the update client; meant to be used as singleton.
pub fn init(allocator: Allocator, config: *const Config) !Updater {
    Network.globalInit(allocator);
    errdefer Network.globalDeinit();
    const x509_store = try Network.createX509Store(allocator);

    return .{
        .x509_store = x509_store,
        .config = config,
    };
}

pub fn deinit(self: *Updater) void {
    Network.globalDeinit();
    crypto.X509_STORE_free(self.x509_store);
}

/// Sends running Lightpanda version to remote to get update information.
/// Outputs directly to given `Writer`.
pub fn inform(self: *Updater, writer: *std.Io.Writer) !void {
    const conn = try http.Connection.init(self.x509_store, self.config, null);
    conn.deinit();
    return writer.flush();
}
