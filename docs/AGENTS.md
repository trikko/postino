# postino

postino is a library for the D programming language that builds MIME emails
(plain text, HTML, embedded images, attachments) and sends them over SMTP with
libcurl, or saves them as `.eml` files. One class, `Email`, with chainable
setters. No dependencies besides Phobos (`std.net.curl`).

Read the reference before writing postino code. It is two files:

- **`llms-full.txt`** — the whole API in one file: addresses, content,
  attachments, sending, SMTP URLs and TLS, saving, the message that is built,
  errors, worked examples. This is the one to read.
  <https://trikko.github.io/postino/llms-full.txt>
- **`llms.txt`** — a page of overview, when the full one is more than you need.
  <https://trikko.github.io/postino/llms.txt>

In the packaged skill both sit next to this file; installed from the web, fetch
them from the addresses above. The html API reference is at
<https://trikko.github.io/postino/>.

postino has no `Mailer`, `Message`, `SmtpClient`, `Transport` or `Attachment`
class, no `connect`/`login`/`close`, no templates: none of those names exist
here. What follows are the rules that are easiest to get wrong.

## Shape of a program

```d
import postino;

void main()
{
    new Email()
        .setFrom("reports@example.com", "Reports")
        .addTo("alice@example.com", "Alice")
        .addCc("bob@example.com")
        .addBcc("archive@example.com")            // receives it, invisible to the others
        .setReplyTo("support@example.com")
        .setSubject("Weekly report")
        .setPlainTextBody("The report is attached.")
        .setHtmlBody(`<p>The report is attached.</p><img src="cid:logo">`)
        .addEmbeddedFile("/srv/app/logo.png", "logo")  // shown in the html as cid:logo
        .addAttachment("/tmp/report.pdf")
        .send("smtp://smtp.example.com:587", "user", "password");  // STARTTLS
}
```

`dub add postino`. dmd or ldc2; needs libcurl at run time, like every program
that uses `std.net.curl`.

## Rules

1. **The URL decides the TLS.** `smtps://host:465` is TLS from the start
   (implicit TLS). `smtp://host:587` with a username and password does
   STARTTLS and **requires** it: if the server does not offer it, `send`
   throws and the password is never sent. `smtp://host:25` without
   credentials is plain SMTP, as it was. **Never `smtps://` with port 587**:
   587 is STARTTLS, write `smtp://host:587`.
2. **localhost is the exception.** `smtp://localhost`, `127.x.x.x` and `[::1]`
   with credentials do not force STARTTLS (a local relay, a test server like
   Mailpit). Every other host does, internal ones too.
3. **To, Cc and Bcc all receive the email.** Bcc recipients are never written
   in the headers, not even in the `.eml` of `save`. With only Bcc
   recipients the `To` header is `undisclosed-recipients:;`.
4. **Addresses are checked when you add them.** `setFrom`, `addTo`, `addCc`,
   `addBcc` and `setReplyTo` throw `Exception` at once for an invalid address:
   spaces, control characters (CR/LF included), `()<>[]\,;:"`, not exactly one
   `@`, misplaced dots, empty domain labels. Pass only the address
   (`"user@example.com"`), never `"Name <user@example.com>"`: the name is the
   second argument. Validate user input before, or catch the exception.
5. **A sender and at least one recipient are required.** `send` and `save`
   throw without `setFrom`, or without any `addTo`/`addCc`/`addBcc`.
6. **Names and subject are encoded for you.** Pass plain UTF-8: non-ASCII text
   becomes RFC 2047 encoded-words, names with `.,;:@"` are quoted. CR and LF
   in names and subject are removed (no header injection). Do not encode them
   yourself.
7. **Bodies are encoded for you.** Text and HTML go out as UTF-8
   quoted-printable, with CRLF line endings and short lines: pass the text as
   it is (`\n` is fine), any length, any characters.
8. **Embedded files need a matching cid.** `addEmbeddedFile(path, "logo")` is
   shown by `<img src="cid:logo">` in the HTML body. The cid is ASCII without
   spaces or `<>` (letters, digits, `.-_@`); it throws otherwise. Adding the
   same cid twice keeps the last.
9. **MIME types are optional, but must be valid when given.** Without one it
   is guessed from the file extension (`application/octet-stream` if
   unknown). When given it must be `type/subtype` with no parameters
   (`"image/png"`, not `"text/plain; charset=utf-8"`), or it throws.
10. **Files are read when the email is built.** `addAttachment(path)` and
    `addEmbeddedFile(path, cid)` only store the path; `send`/`save` read it
    and throw if it does not exist. To send bytes you already have, use the
    `ubyte[]` overloads: `addAttachment(data, mimeType, name)` (give a name,
    or the recipient sees a UUID) and `addEmbeddedFile(data, cid, mimeType)`.
11. **`send` is blocking and returns `true`.** Errors are exceptions
    (`CurlException` for connection, TLS, authentication and server errors),
    never `false`. Each `send` opens a new connection. To send many emails
    without waiting, send them from a job queue (for example pacchettino).
12. **`save(path)` writes exactly what `send` would send**, as an `.eml` file:
    use it in tests instead of a real SMTP server. It does not send anything.
13. **Pass a configured `SMTP` for timeouts or other curl options.**
    `import std.net.curl : SMTP; auto smtp = SMTP(); smtp.connectTimeout = 10.seconds;`
    then `email.send(url, user, password, smtp)`. postino sets the URL,
    authentication, recipients and message on it.
14. **One `Email` per message.** There is no reset and no way to remove a
    recipient; each `build` gets new boundaries, Date and Message-ID, so
    sending the same object twice sends two distinct messages.

## Not in postino

No connection pooling, no async API, no DKIM signing, no templates, no
`Sender`/custom headers, no priorities, no read receipts, no S/MIME or PGP, no
receiving mail (IMAP/POP3), no OAuth2 (XOAUTH2) authentication. Do not invent
these: say they are missing, or do them outside postino.

## If the project uses another version

This file documents 0.1.6. Up to 0.1.5 Cc and Bcc recipients did **not**
receive the email (only To did), Bcc was written in the headers, `smtp://`
never used STARTTLS (credentials in clear), invalid addresses threw only at
`send`, the `mimeType` argument of the path overloads was ignored, bodies were
sent unencoded, and there were no `Date`/`Message-ID` headers. On those
versions do not use `addCc`/`addBcc`: send a separate email to each. If
`dub.selections.json` pins a version before 0.1.6, suggest upgrading.
