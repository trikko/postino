# <img align="left" alt="postino logo" width="100" height="100" src="https://github.com/trikko/postino/raw/main/logo.png"> postino

[![CI](https://github.com/trikko/postino/actions/workflows/ci.yml/badge.svg)](https://github.com/trikko/postino/actions/workflows/ci.yml)
[![DUB](https://img.shields.io/dub/v/postino)](https://code.dlang.org/packages/postino)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**postino** (Italian for «postman») sends email from programs written in D.
You describe the message with a few chained calls: sender, recipients,
subject, text and HTML body, images, attachments. postino builds a correct
MIME message and delivers it over SMTP, or saves it as an `.eml` file. It uses
libcurl through Phobos' `std.net.curl` and has no other dependencies.

**Documentation:** [API reference](https://trikko.github.io/postino/) ·
[for AI agents](#using-postino-with-an-ai-agent) · `dub add postino`

## Features

- **Text and HTML** in the same email, with images shown inside the HTML
  (`<img src="cid:logo">`) and attachments, from files or from memory.
- **Any language**: subjects, names, bodies and file names in UTF-8 are
  encoded as the standards require, long lines included.
- **TLS**: `smtps://` for implicit TLS, STARTTLS on `smtp://`. When you send a
  password, STARTTLS is mandatory: it never travels in clear.
- **Checked input**: an invalid address, header, Content-ID or MIME type throws
  a `PostinoException` as soon as you add it, and CR/LF in subjects or names
  can't inject headers. Internationalized domains are converted to punycode.
- **Custom headers**: `List-Unsubscribe` for newsletters, `In-Reply-To` and
  `References` for replies, `X-...`.
- **OAuth2**: `send(url, user, OAuth2(token))` for Gmail and Microsoft 365
  without passwords.
- **Many emails**: `clone()` a message for each recipient and reuse one
  connection for all of them.
- **Save instead of send**: `save("mail.eml")` writes exactly the message
  `send` would deliver. Open it in a mail client, or check it in your tests.
- **Small**: one class, `Email`, in one file, tested against a real SMTP
  server (Mailpit) on every push.

## Quick Start

### Installation

Add postino to your `dub.json` or use DUB directly:

```bash
dub add postino
```

### Basic Usage

```d
import postino;

void main()
{
   auto email = new Email();

   // Method chaining
   email
   .setFrom("sender@example.com", "John Doe")
   .addTo("recipient@example.com", "Jane Smith")
   .setSubject("Hello from postino!")
   .setPlainTextBody("Hello, this is a plain text email.")
   .setHtmlBody("<h1>Hello!</h1><p>This is an <b>HTML</b> email.</p>")
   .send("smtps://smtp.example.com:465", "username", "password");
}
```

## Advanced Examples

### HTML Email with Embedded Image

```d
   new Email()
   .setFrom("newsletter@example.com", "Company Newsletter")
   .addTo("customer@example.com", "Valued Customer")
   .setSubject("Monthly Newsletter")
   .setHtmlBody(`
      <html>
      <body>
         <h1>Welcome to our Newsletter!</h1>
         <p>Check out our latest product:</p>
         <img src="cid:product-image" alt="New Product" width="300">
         <p>Best regards,<br>The Team</p>
      </body>
      </html>
   `)
   .embedFile("/path/to/product.png", "product-image")
   .send("smtps://smtp.example.com:465", "username", "password");
```

### Multiple Recipients with Attachments

```d
   new Email()
   .setFrom("reports@example.com", "Automated Reports")
   .addTo("manager@example.com", "Project Manager")
   .addTo("team@example.com", "Development Team")
   .addCc("archive@example.com")
   .setSubject("Weekly Report")
   .setPlainTextBody("Please find the weekly report attached.")
   .attachFile("/path/to/report.pdf")
   .attachFile("/path/to/data.xlsx")
   .send("smtp://internal-smtp.example.com:25");
```

### Newsletter with Multiple Features

```d
new Email()
    .setFrom("marketing@example.com", "Marketing Team")
    .addTo("subscriber1@example.com", "John Doe")
    .addTo("subscriber2@example.com", "Jane Smith")
    .addBcc("analytics@example.com")
    .setReplyTo("support@example.com", "Customer Support")
    .setSubject("🎉 Special Offer Inside!")
    .setPlainTextBody("Visit our website for a special 20% discount!")
    .setHtmlBody(`
        <html>
        <body style="font-family: Arial, sans-serif;">
            <h1>🎉 Special Offer!</h1>
            <p>Get <strong>20% off</strong> your next purchase!</p>
            <img src="cid:banner" alt="Special Offer" style="max-width: 100%;">
            <p><a href="https://example.com/offer">Shop Now</a></p>
        </body>
        </html>
    `)
    .embedFile("/path/to/banner.jpg", "banner")
    .attachFile("/path/to/catalog.pdf")
    .send("smtp://smtp.example.com:587", "marketing@example.com", "password");
```

## API Reference

### Email Configuration (Chainable)

| Method | Description |
|--------|-------------|
| `setFrom(address, name?)` | Set sender email and optional display name |
| `addTo(address, name?)` | Add recipient to "To" field |
| `addCc(address, name?)` | Add recipient to "Cc" field |
| `addBcc(address, name?)` | Add hidden recipient: receives the email, never written in the headers |
| `setReplyTo(address, name?)` | Set reply-to address |
| `setSubject(subject)` | Set email subject |
| `addHeader(name, value)` | Add a custom header (`List-Unsubscribe`, `In-Reply-To`, `X-...`) |

### Content (Chainable)

| Method | Description |
|--------|-------------|
| `setPlainTextBody(text)` | Set plain text content |
| `setHtmlBody(html)` | Set HTML content |
| `attachFile(path, mimeType?, name?)` | Attach a file (read when sending) |
| `addAttachment(data, mimeType, name?)` | Attach data from memory (copied) |
| `embedFile(path, cid, mimeType?)` | Embed a file for the HTML (`<img src="cid:...">`) |
| `addEmbeddedFile(data, cid, mimeType)` | Embed data from memory (copied) |

Invalid addresses, headers, Content-IDs and MIME types throw a `PostinoException` as soon as they are added.
Internationalized domains are fine: `info@città.it` is sent as `info@xn--citt-3na.it`.

### Copying and clearing (Chainable)

| Method | Description |
|--------|-------------|
| `clone()` | Independent copy of the email, e.g. to send the same message to many people |
| `clearTo()`, `clearCc()`, `clearBcc()` | Remove the recipients added with the matching `add*` |
| `clearHeaders()`, `clearAttachments()`, `clearEmbeddedFiles()` | Remove what the matching `add*` added |

### Sending and saving

| Method | Description |
|--------|-------------|
| `send(smtpUrl, username?, password?, smtp?)` | Send email via SMTP to every To, Cc and Bcc recipient |
| `send(smtpUrl, username, OAuth2(token), smtp?)` | Same, authenticating with an OAuth 2.0 token (XOAUTH2) |
| `save(path)` | Save the same message as a .eml file, without sending it |


## SMTP Configuration

The URL decides how the connection is secured:

| URL | Security |
|---|---|
| `smtps://host:465` | TLS from the start (implicit TLS) |
| `smtp://host:587` with username and password | STARTTLS, required: if the server does not offer it, `send` fails and the password is never sent |
| `smtp://host:25` without credentials | plain SMTP, as the server allows |
| `smtp://localhost:...` | plain SMTP, also with credentials (local test servers) |

Port 587 is STARTTLS: use `smtp://`, not `smtps://`, with it. Credentials go
to `send`, never in the URL: `smtp://user:pass@host` is refused.

```d
// Gmail with app password
email.send("smtps://smtp.gmail.com:465", "user@gmail.com", "app-password");

// Outlook/Hotmail (STARTTLS)
email.send("smtp://smtp-mail.outlook.com:587", "user@outlook.com", "password");

// Local SMTP server (no auth)
email.send("smtp://localhost:25");

// Custom SMTP with TLS
email.send("smtps://mail.example.com:465", "user", "pass");
```

Pass a configured `std.net.curl.SMTP` as last argument for timeouts and other curl options:

```d
import std.net.curl : SMTP;
import core.time : seconds;

auto smtp = SMTP();
smtp.connectTimeout = 10.seconds;
email.send("smtp://smtp.example.com:587", "user", "password", smtp);
```

### OAuth2

Gmail and Microsoft 365 can require OAuth2 instead of a password. Get an access
token with the provider's OAuth flow (postino does not get or refresh it), then:

```d
email.send("smtp://smtp.office365.com:587", "user@example.com", OAuth2(accessToken));
```

### Many emails

Pass the same `SMTP` object to every `send` and the connection is reused. With
`clone()` the message is built once and sent to each recipient separately:

```d
auto newsletter = new Email()
    .setFrom("news@example.com", "Example News")
    .setSubject("November news")
    .setHtmlBody(html);

auto smtp = SMTP();

foreach (s; subscribers)
    newsletter.clone()
        .addTo(s.email, s.name)
        .addHeader("List-Unsubscribe", "<https://example.com/unsubscribe?id=" ~ s.id ~ ">")
        .addHeader("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")
        .send("smtp://smtp.example.com:587", "user", "password", smtp);
```

## Feedback & support
Using postino? I'd love to hear what you're building with it, or what's missing.
Write to me: the address is just **oss**, at the domain of [my website](https://andreafontana.it).

postino is built in my spare time. If it's useful to you or your company,
consider [sponsoring me on GitHub](https://github.com/sponsors/trikko)
or [buying me a beer on PayPal](https://paypal.me/andreafontana) ❤️

## Using postino with an AI agent

postino is small and not well known, so it is barely in the training data of
the models: a model left to guess writes code for another email library, or
invents one. Give it the reference instead:

* [SKILL.md](https://trikko.github.io/postino/SKILL.md): the rules that are
  easiest to get wrong, as a skill. [AGENTS.md](https://trikko.github.io/postino/AGENTS.md)
  is the same text without the front matter, for tools that want a rules file
  (`AGENTS.md`, `CLAUDE.md`, `.cursorrules`, ...).
* [llms-full.txt](https://trikko.github.io/postino/llms-full.txt): the whole API;
  [llms.txt](https://trikko.github.io/postino/llms.txt): a short overview.

The easiest way: ask your agent to do it.

> Install the skill at https://trikko.github.io/postino/SKILL.md. It is the
> reference for postino, the D email library I am using.

Or by hand: a skill is a folder with `SKILL.md` in it (`llms-full.txt` next to
it saves a download).

| Tool | For all projects | For one project |
|---|---|---|
| Claude Code | `~/.claude/skills/postino/` | `.claude/skills/postino/` |
| Antigravity (IDE, 2.0) | `~/.gemini/config/skills/postino/` | `.agents/skills/postino/` |
| Antigravity CLI | `~/.gemini/antigravity-cli/skills/postino/` | `.agents/skills/postino/` |
| Gemini CLI | `~/.gemini/skills/postino/` | `.gemini/skills/postino/` |
| Codex | `~/.agents/skills/postino/` | `.agents/skills/postino/` |

For example, for Claude Code:

```sh
mkdir -p ~/.claude/skills/postino && cd ~/.claude/skills/postino
curl -fsSLO https://trikko.github.io/postino/SKILL.md
curl -fsSLO https://trikko.github.io/postino/llms-full.txt
```

The skill is loaded when the task is about postino or sending email in D; in
Claude Code you can also call it with `/postino`.

## Development

```sh
dub test            # unit tests, no SMTP server needed
tests/mailpit.sh    # end-to-end tests: sends to two Mailpit servers in docker and checks what arrived
tools/docs.sh       # regenerate the documentation in docs/
```

The html reference in `docs/`, served by GitHub Pages, is generated from the
comments in the source with `tools/docs.sh` (ddox with the scod skin).
`docs/AGENTS.md`, `docs/llms.txt` and `docs/llms-full.txt` are written by hand;
`docs/SKILL.md` is generated from `AGENTS.md`.

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
