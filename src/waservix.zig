//! Zig client for the WAservix WhatsApp API Gateway (https://tekservix.com/waservix/).
//!
//! WAservix links your own WhatsApp number by QR code (the same way WhatsApp Web does) and
//! gives you a REST API to send text, images, documents, locations and polls.
//! Needs a Tekservix account with WAservix and your number's API key. Keep it on your server.

const std = @import("std");

pub const version = "1.0.0";
pub const default_base_url = "https://tekservix.com/waservix/api";

pub const Header = struct { name: []const u8, value: []const u8 };

/// What a transport returns. `body` is owned by the caller (allocated with the given allocator).
pub const HttpResponse = struct { status: u16, body: []u8 };

/// Sends one HTTP request. Replace it for tests, proxies or custom TLS.
pub const Transport = struct {
    ctx: ?*anyopaque = null,
    send: *const fn (ctx: ?*anyopaque, gpa: std.mem.Allocator, method: std.http.Method, url: []const u8, headers: []const Header, body: ?[]const u8) anyerror!HttpResponse,
};

/// Details of the last API error (set when a call returns `error.ApiError`). A 503 means the number is reconnecting.
pub const ApiError = struct {
    status: u16 = 0,
    message: []const u8 = "",
};

/// A decoded answer. `data()` is the API's `data` field. Call `deinit()` when done.
pub const Result = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn data(self: Result) std.json.Value {
        if (self.parsed.value == .object) {
            if (self.parsed.value.object.get("data")) |d| return d;
        }
        return self.parsed.value;
    }

    pub fn deinit(self: Result) void {
        self.parsed.deinit();
    }
};

pub const Options = struct {
    base_url: []const u8 = default_base_url,
    transport: ?Transport = null,
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8,
    transport: Transport,
    last_error: ApiError = .{},
    message_buf: ?[]u8 = null,

    /// Create a client with your number's API key (Devices in the WAservix dashboard).
    pub fn init(gpa: std.mem.Allocator, api_key: []const u8, opts: Options) !Client {
        if (api_key.len == 0) return error.MissingApiKey;
        return .{
            .gpa = gpa,
            .api_key = api_key,
            .base_url = std.mem.trimRight(u8, opts.base_url, "/"),
            .transport = opts.transport orelse .{ .send = httpSend },
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.message_buf) |m| self.gpa.free(m);
        self.message_buf = null;
    }

    fn setError(self: *Client, status: u16, message: []const u8) !void {
        if (self.message_buf) |m| self.gpa.free(m);
        self.message_buf = try self.gpa.dupe(u8, message);
        self.last_error = .{ .status = status, .message = self.message_buf.? };
    }

    /// Call any documented endpoint, e.g. `client.request(.GET, "/groups", null)`.
    /// On failure returns `error.ApiError` and fills `client.last_error`.
    pub fn request(self: *Client, method: std.http.Method, path: []const u8, body: ?[]const u8) !Result {
        const url = try std.mem.concat(self.gpa, u8, &.{ self.base_url, path });
        defer self.gpa.free(url);
        const auth = try std.mem.concat(self.gpa, u8, &.{ "Bearer ", self.api_key });
        defer self.gpa.free(auth);
        var headers_buf: [4]Header = undefined;
        var n: usize = 0;
        headers_buf[n] = .{ .name = "Authorization", .value = auth };
        n += 1;
        headers_buf[n] = .{ .name = "Accept", .value = "application/json" };
        n += 1;
        headers_buf[n] = .{ .name = "User-Agent", .value = "waservix-zig/" ++ version };
        n += 1;
        if (body != null) {
            headers_buf[n] = .{ .name = "Content-Type", .value = "application/json" };
            n += 1;
        }

        const res = self.transport.send(self.transport.ctx, self.gpa, method, url, headers_buf[0..n], body) catch |err| {
            try self.setError(0, @errorName(err));
            return error.ApiError;
        };
        defer self.gpa.free(res.body);

        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, if (res.body.len == 0) "null" else res.body, .{}) catch {
            if (res.status >= 400) {
                var buf: [32]u8 = undefined;
                try self.setError(res.status, try std.fmt.bufPrint(&buf, "HTTP {d}", .{res.status}));
                return error.ApiError;
            }
            return error.InvalidResponse;
        };
        var failed = res.status >= 400;
        var message: ?[]const u8 = null;
        if (parsed.value == .object) {
            if (parsed.value.object.get("success")) |s| {
                if (s == .bool and !s.bool) failed = true;
            }
            if (parsed.value.object.get("message")) |m| {
                if (m == .string) message = m.string;
            }
        }
        if (failed) {
            defer parsed.deinit();
            if (message) |m| {
                try self.setError(res.status, m);
            } else {
                var buf: [32]u8 = undefined;
                try self.setError(res.status, try std.fmt.bufPrint(&buf, "HTTP {d}", .{res.status}));
            }
            return error.ApiError;
        }
        return .{ .parsed = parsed };
    }

    /// Send any message type to a number or group JID (`...@g.us`). `fields` is any struct with the
    /// API's field names (text, imageUrl, documentUrl, fileName, location, poll, ...); null fields are skipped.
    pub fn sendMessage(self: *Client, to: []const u8, fields: anytype) !Result {
        if (to.len == 0) return error.MissingRecipient;
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        var w: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
        try w.beginObject();
        try w.objectField("to");
        try w.write(to);
        inline for (std.meta.fields(@TypeOf(fields))) |f| {
            const v = @field(fields, f.name);
            const is_null = switch (@typeInfo(f.type)) {
                .optional => v == null,
                else => false,
            };
            if (!is_null) {
                try w.objectField(f.name);
                try w.write(v);
            }
        }
        try w.endObject();
        return self.request(.POST, "/send-message", out.written());
    }

    pub fn sendText(self: *Client, to: []const u8, text: []const u8) !Result {
        return self.sendMessage(to, .{ .text = text });
    }

    pub fn sendImage(self: *Client, to: []const u8, image_url: []const u8, caption: ?[]const u8) !Result {
        return self.sendMessage(to, .{ .imageUrl = image_url, .text = caption });
    }

    pub fn sendDocument(self: *Client, to: []const u8, document_url: []const u8, file_name: ?[]const u8, caption: ?[]const u8) !Result {
        return self.sendMessage(to, .{ .documentUrl = document_url, .fileName = file_name, .text = caption });
    }

    /// Status: queued, sent, delivered, read, played or failed.
    pub fn getMessageInfo(self: *Client, id: []const u8) !Result {
        const path = try std.fmt.allocPrint(self.gpa, "/messages/{s}/info", .{id});
        defer self.gpa.free(path);
        return self.request(.GET, path, null);
    }

    /// Is this number on WhatsApp? Returns `{"exists": bool, "jid": ...}`.
    pub fn onWhatsApp(self: *Client, phone: []const u8) !Result {
        const escaped = try escapePath(self.gpa, phone);
        defer self.gpa.free(escaped);
        const path = try std.fmt.allocPrint(self.gpa, "/on-whatsapp/{s}", .{escaped});
        defer self.gpa.free(path);
        return self.request(.GET, path, null);
    }

    /// connected, connecting, need_scan, disconnected, logged_out or expired.
    pub fn getStatus(self: *Client) !Result {
        return self.request(.GET, "/status", null);
    }

    pub fn listGroups(self: *Client) !Result {
        return self.request(.GET, "/groups", null);
    }

    pub fn listContacts(self: *Client) !Result {
        return self.request(.GET, "/contacts", null);
    }
};

fn escapePath(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try out.append(gpa, c);
        } else {
            try out.print(gpa, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Constant-time check of the `X-Webhook-Signature` header against your number's webhook secret.
pub fn verifyWebhook(signature: []const u8, secret: []const u8) bool {
    if (signature.len == 0 or secret.len == 0 or signature.len != secret.len) return false;
    var diff: u8 = 0;
    for (signature, secret) |a, b| diff |= a ^ b;
    return diff == 0;
}

fn httpSend(_: ?*anyopaque, gpa: std.mem.Allocator, method: std.http.Method, url: []const u8, headers: []const Header, body: ?[]const u8) anyerror!HttpResponse {
    var client: std.http.Client = .{ .allocator = gpa };
    defer client.deinit();
    const extra = try gpa.alloc(std.http.Header, headers.len);
    defer gpa.free(extra);
    for (headers, 0..) |h, i| extra[i] = .{ .name = h.name, .value = h.value };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = body,
        .extra_headers = extra,
        .response_writer = &out.writer,
    });
    return .{ .status = @intFromEnum(res.status), .body = try out.toOwnedSlice() };
}

// ------------------------------------------------------------------------------- tests

const Fake = struct {
    status: u16 = 200,
    reply: []const u8 = "{\"success\":true,\"data\":{\"msgId\":58213,\"status\":\"in_progress\"}}",
    method: std.http.Method = .GET,
    url: [256]u8 = undefined,
    url_len: usize = 0,
    body: [512]u8 = undefined,
    body_len: usize = 0,
    auth: [64]u8 = undefined,
    auth_len: usize = 0,

    fn send(ctx: ?*anyopaque, gpa: std.mem.Allocator, method: std.http.Method, url: []const u8, headers: []const Header, body: ?[]const u8) anyerror!HttpResponse {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        self.method = method;
        @memcpy(self.url[0..url.len], url);
        self.url_len = url.len;
        const b = body orelse "";
        @memcpy(self.body[0..b.len], b);
        self.body_len = b.len;
        for (headers) |h| {
            if (std.mem.eql(u8, h.name, "Authorization")) {
                @memcpy(self.auth[0..h.value.len], h.value);
                self.auth_len = h.value.len;
            }
        }
        return .{ .status = self.status, .body = try gpa.dupe(u8, self.reply) };
    }

    fn transport(self: *Fake) Transport {
        return .{ .ctx = self, .send = send };
    }
};

test "send text" {
    var fake = Fake{};
    var c = try Client.init(std.testing.allocator, "wpk_test", .{ .base_url = "https://example.test/api", .transport = fake.transport() });
    defer c.deinit();
    const res = try c.sendText("+1555", "hi");
    defer res.deinit();
    try std.testing.expectEqual(@as(i64, 58213), res.data().object.get("msgId").?.integer);
    try std.testing.expectEqualStrings("https://example.test/api/send-message", fake.url[0..fake.url_len]);
    try std.testing.expectEqualStrings("Bearer wpk_test", fake.auth[0..fake.auth_len]);
    try std.testing.expectEqualStrings("{\"to\":\"+1555\",\"text\":\"hi\"}", fake.body[0..fake.body_len]);
}

test "media and paths" {
    var fake = Fake{};
    var c = try Client.init(std.testing.allocator, "k", .{ .base_url = "https://example.test/api", .transport = fake.transport() });
    defer c.deinit();
    (try c.sendImage("+1", "https://x/y.jpg", null)).deinit();
    try std.testing.expectEqualStrings("{\"to\":\"+1\",\"imageUrl\":\"https://x/y.jpg\"}", fake.body[0..fake.body_len]);
    (try c.sendDocument("+1", "https://x/a.pdf", "a.pdf", "c")).deinit();
    try std.testing.expectEqualStrings("{\"to\":\"+1\",\"documentUrl\":\"https://x/a.pdf\",\"fileName\":\"a.pdf\",\"text\":\"c\"}", fake.body[0..fake.body_len]);
    (try c.getMessageInfo("5")).deinit();
    try std.testing.expectEqualStrings("https://example.test/api/messages/5/info", fake.url[0..fake.url_len]);
    (try c.onWhatsApp("+1555")).deinit();
    try std.testing.expectEqualStrings("https://example.test/api/on-whatsapp/%2B1555", fake.url[0..fake.url_len]);
    try std.testing.expectError(error.MissingRecipient, c.sendText("", "x"));
    try std.testing.expectError(error.MissingApiKey, Client.init(std.testing.allocator, "", .{}));
}

test "api errors" {
    var fake = Fake{ .status = 503, .reply = "{\"success\":false,\"message\":\"Device reconnecting\"}" };
    var c = try Client.init(std.testing.allocator, "k", .{ .transport = fake.transport() });
    defer c.deinit();
    try std.testing.expectError(error.ApiError, c.getStatus());
    try std.testing.expectEqual(@as(u16, 503), c.last_error.status);
    try std.testing.expectEqualStrings("Device reconnecting", c.last_error.message);
    fake.status = 200;
    fake.reply = "{\"success\":false,\"message\":\"Invalid number\"}";
    try std.testing.expectError(error.ApiError, c.sendText("+1", "x"));
    try std.testing.expectEqualStrings("Invalid number", c.last_error.message);
}

test "webhook secret" {
    try std.testing.expect(verifyWebhook("abc", "abc"));
    try std.testing.expect(!verifyWebhook("abd", "abc"));
    try std.testing.expect(!verifyWebhook("abcd", "abc"));
    try std.testing.expect(!verifyWebhook("", "abc"));
}
