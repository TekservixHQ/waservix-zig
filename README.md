# waservix (Zig)

[![tests](https://github.com/TekservixHQ/waservix-zig/actions/workflows/tests.yml/badge.svg)](https://github.com/TekservixHQ/waservix-zig/actions/workflows/tests.yml)

**WAservix WhatsApp API Gateway** - official Zig client: send WhatsApp messages from your own number. By Tekservix.

Zig client for the [WAservix WhatsApp API Gateway](https://tekservix.com/waservix/).

WAservix links your own WhatsApp number by QR code (the same way WhatsApp Web does) and gives you a REST API to send text, images, documents, locations and polls.

Zig 0.15.1+, standard library only (std.http, std.json, std.crypto).

## Install

```bash
zig fetch --save git+https://github.com/TekservixHQ/waservix-zig#v1.0.0
```

Then in `build.zig`:

```zig
const waservix = b.dependency("waservix", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("waservix", waservix.module("waservix"));
```

## Usage

You need a Tekservix account with WAservix and your number's API key (Devices in the dashboard). Keep it on your server.

```zig
const std = @import("std");
const waservix = @import("waservix");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const api_key = std.posix.getenv("WASERVIX_KEY") orelse return error.MissingKey;

    var c = try waservix.Client.init(gpa, api_key, .{});
    defer c.deinit();

    const res = c.sendText("+15551234567", "Hello Aline, your order is ready") catch |err| {
        if (err == error.ApiError) std.debug.print("WAservix: {s} (HTTP {d})\n", .{ c.last_error.message, c.last_error.status });
        return err;
    };
    defer res.deinit();
    // res.data() is {"msgId": ..., "status": "in_progress"}

    (try c.sendDocument("+15551234567", "https://example.com/inv.pdf", "Invoice.pdf", "Your invoice")).deinit();
    // Any field the API supports, including groups (JID ending in @g.us)
    (try c.sendMessage("120363040000000000@g.us", .{ .text = "Team meeting at 3pm" })).deinit();

    (try c.getMessageInfo("58213")).deinit();   // queued, sent, delivered, read, played or failed
    (try c.onWhatsApp("+15551234567")).deinit();
    (try c.request(.GET, "/groups", null)).deinit();   // any other endpoint
}
```

Every call returns a `Result` (call `deinit()`), or `error.ApiError` with details in `client.last_error`. The HTTP transport can be replaced (`.transport` option) for tests or proxies.

Webhooks carry `X-Webhook-Signature`, which equals your number's webhook secret: check it with `waservix.verifyWebhook(signature, secret)`. A 503 error means the number is reconnecting.

## More from Tekservix

- [SMS Gora SMS Gateway](https://tekservix.com/smsgora/) ([Zig client](https://github.com/TekservixHQ/smsgora-zig))
- [AI Sales Agent](https://tekservix.com/ai-sales-agent) and [Website to App](https://tekservix.com/mobile-apps)
- Libraries for many more languages: [github.com/TekservixHQ](https://github.com/TekservixHQ)

## License

MIT
