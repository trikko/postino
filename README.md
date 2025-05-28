# QuickMail

A simple and secure MIME email library for D with support for HTML, attachments, and embedded files.

## Features

- 🚀 **Simple API** - Send emails with just a few lines of code
- 📧 **MIME Support** - Full multipart/alternative and multipart/related support
- 📎 **Attachments** - Support for file attachments and embedded images
- 🎨 **HTML Emails** - Send rich HTML emails with embedded images

## Quick Start

### Installation

Add QuickMail to your `dub.json` or use DUB directly:

```bash
dub add quickmail
```

### Basic Usage

```d
import quickmail;

void main()
{
   auto email = new Email();

   // Method chaining
   email
   .setFrom("sender@example.com", "John Doe")
   .addTo("recipient@example.com", "Jane Smith")
   .setSubject("Hello from QuickMail!")
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
   .addEmbeddedFile("/path/to/product.png", "product-image")
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
   .addAttachment("/path/to/report.pdf")
   .addAttachment("/path/to/data.xlsx")
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
    .addEmbeddedFile("/path/to/banner.jpg", "banner")
    .addAttachment("/path/to/catalog.pdf")
    .send("smtps://smtp.example.com:587", "marketing@example.com", "password");
```

## API Reference

### Email Configuration (Chainable)

| Method | Description | Returns |
|--------|-------------|---------|
| `setFrom(address, name?)` | Set sender email and optional display name | `ref Email` |
| `addTo(address, name?)` | Add recipient to "To" field | `ref Email` |
| `addCc(address, name?)` | Add recipient to "Cc" field | `ref Email` |
| `addBcc(address, name?)` | Add recipient to "Bcc" field | `ref Email` |
| `setReplyTo(address, name?)` | Set reply-to address | `ref Email` |
| `setSubject(subject)` | Set email subject | `ref Email` |

### Content (Chainable)

| Method | Description | Returns |
|--------|-------------|---------|
| `setPlainTextBody(text)` | Set plain text content | `ref Email` |
| `setHtmlBody(html)` | Set HTML content | `ref Email` |
| `addAttachment(path, mimeType?)` | Add file attachment | `ref Email` |
| `addEmbeddedFile(path, cid, mimeType?)` | Add embedded file for HTML | `ref Email` |

### Sending

| Method | Description | Returns |
|--------|-------------|---------|
| `send(smtpUrl, username?, password?)` | Send email via SMTP | `bool` |


## SMTP Configuration

QuickMail supports various SMTP configurations:

```d
// Gmail with app password
email.send("smtps://smtp.gail.com:465", "user@gmail.com", "app-password");

// Outlook/Hotmail
email.send("smtps://smtp-mail.outlook.com:587", "user@outlook.com", "password");

// Local SMTP server (no auth)
email.send("smtp://localhost:25");

// Custom SMTP with TLS
email.send("smtps://mail.example.com:465", "user", "pass");
```

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
