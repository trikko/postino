/**
 * postino: build MIME emails (plain text, HTML, embedded images, attachments)
 * and send them over SMTP, or save them as .eml files.
 *
 * Example:
 * ---
 * new Email()
 *     .setFrom("sender@example.com", "Sender")
 *     .addTo("alice@example.com", "Alice")
 *     .setSubject("Hello")
 *     .setPlainTextBody("Hello Alice")
 *     .send("smtp://smtp.example.com:587", "user", "password");
 * ---
 */
module postino;

import std.algorithm : map, sort;
import std.array : array, join, split;
import std.algorithm.searching : canFind;
import std.string : replace, toLower, strip;
import std.conv : to;
import std.file : exists, read;
import std.path : baseName, extension;
import std.base64 : Base64;
import std.datetime : Clock, SysTime;
import std.range : chunks;
import std.net.curl : SMTP;
import std.utf : toUTF8, stride;
import std.format : format;
import std.algorithm.searching : startsWith, endsWith, count;
import etc.c.curl : CurlOption, CurlUseSSL;

/**
 * Thrown by postino for invalid input: an invalid address, header, Content-ID or MIME type,
 * a missing sender, recipient or file. Errors of the connection and of the SMTP server
 * are std.net.curl.CurlException.
 */
class PostinoException : Exception
{
	this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
	{
		super(msg, file, line);
	}
}

/**
 * An OAuth 2.0 access token, for Email.send(url, username, OAuth2(token)).
 * A type of its own, so that a token can't be passed as a password by mistake.
 */
struct OAuth2
{
	/// The access token, as given by the provider (Google, Microsoft, ...)
	string accessToken;
}

/**
 * An email message. Every setter returns the same object, so calls can be chained.
 * Addresses are checked when they are added; send() delivers to every To, Cc and Bcc
 * recipient, and save() writes the same message as an .eml file.
 */
class Email
{
	/**
	 * Sets the sender's email address and optional display name.
	 *
	 * Params:
	 *     address = The sender's email address
	 *     name = Optional display name for the sender
	 *
	 * Returns: Reference to this Email object for method chaining
	 *
	 * Throws: PostinoException if the address is not a valid email address
	 *
	 * Example:
	 * ---
	 * email.setFrom("sender@example.com", "John Doe")
	 *      .addTo("recipient@example.com");
	 * ---
	 */
	auto setFrom(string address, string name = string.init)
	{
		this.from = Recipient(validateEmailAddress(address), validateText("name", name));
		return this;
	}

	/**
	 * Adds a recipient to the email's "To" field.
	 * Multiple recipients can be added by calling this method multiple times.
	 *
	 * Params:
	 *     address = The recipient's email address
	 *     name = Optional display name for the recipient
	 *
	 * Returns: Reference to this Email object for method chaining
	 *
	 * Throws: PostinoException if the address is not a valid email address
	 *
	 * Example:
	 * ---
	 * email.addTo("recipient1@example.com", "Jane Smith")
	 *      .addTo("recipient2@example.com");
	 * ---
	 */
	auto addTo(string address, string name = string.init)
	{
		this.to ~= Recipient(validateEmailAddress(address), validateText("name", name));
		return this;
	}

	/**
	 * Sets the email subject line.
	 * The subject will be automatically encoded if it contains non-ASCII characters.
	 *
	 * Params:
	 *     subject = The email subject
	 *
	 * Returns: Reference to this Email object for method chaining
	 *
	 * Example:
	 * ---
	 * email.setSubject("Important Meeting Tomorrow")
	 *      .addTo("team@example.com");
	 * ---
	 */
	auto setSubject(string subject)
	{
		this.subject = validateText("subject", subject);
		return this;
	}

	/**
	 * Adds a recipient to the email's "Cc" (Carbon Copy) field.
	 * Multiple Cc recipients can be added by calling this method multiple times.
	 * Cc recipients receive the email and are listed in the "Cc" header.
	 *
	 * Params:
	 *     address = The Cc recipient's email address
	 *     name = Optional display name for the recipient
	 *
	 * Returns: Reference to this Email object for method chaining
	 *
	 * Throws: PostinoException if the address is not a valid email address
	 *
	 * Example:
	 * ---
	 * email.addCc("manager@example.com", "Project Manager")
	 *      .addCc("team@example.com");
	 * ---
	 */
	auto addCc(string address, string name = string.init)
	{
		this.cc ~= Recipient(validateEmailAddress(address), validateText("name", name));
		return this;
	}

	/**
	 * Adds a recipient to the email's "Bcc" (Blind Carbon Copy) field.
	 * Multiple Bcc recipients can be added by calling this method multiple times.
	 * Bcc recipients receive the email but are never written in its headers,
	 * so the other recipients cannot see them.
	 *
	 * Params:
	 *     address = The Bcc recipient's email address
	 *     name = Optional display name for the recipient
	 *
	 * Returns: Reference to this Email object for method chaining
	 *
	 * Throws: PostinoException if the address is not a valid email address
	 *
	 * Example:
	 * ---
	 * email.addBcc("archive@example.com", "Email Archive")
	 *      .addBcc("backup@example.com");
	 * ---
	 */
	auto addBcc(string address, string name = string.init)
	{
		this.bcc ~= Recipient(validateEmailAddress(address), validateText("name", name));
		return this;
	}

	/**
	 * Sets the "Reply-To" email address for the email.
	 * This determines where replies to this email will be sent.
	 *
	 * Params:
	 *     address = The reply-to email address
	 *     name = Optional display name for the reply-to address
	 *
	 * Returns: Reference to this Email object for method chaining
	 *
	 * Throws: PostinoException if the address is not a valid email address
	 *
	 * Example:
	 * ---
	 * email.setReplyTo("noreply@example.com", "No Reply")
	 *      .setSubject("Newsletter");
	 * ---
	 */
	auto setReplyTo(string address, string name = string.init)
	{
		this.replyTo = Recipient(validateEmailAddress(address), validateText("name", name));
		return this;
	}

	/**
	 * Sets the plain text body of the email.
	 * This will be displayed in email clients that don't support HTML.
	 *
	 * Params:
	 *     body = The plain text content of the email
	 *
	 * Returns: Reference to this Email object for method chaining
	 *
	 * Example:
	 * ---
	 * email.setPlainTextBody("Hello,\n\nThis is a plain text email.")
	 *      .setHtmlBody("<h1>Hello!</h1>");
	 * ---
	 */
	auto setPlainTextBody(string body)
	{
		this.plainTextBody = validateText("plain text body", body);
		return this;
	}

	/**
	 * Sets the HTML body of the email.
	 * This allows for rich formatting, images, and styling.
	 *
	 * Params:
	 *     body = The HTML content of the email
	 *
	 * Returns: Reference to this Email object for method chaining
	 *
	 * Example:
	 * ---
	 * email.setHtmlBody("<html><body><h1>Hello!</h1></body></html>")
	 *      .addAttachment("/path/to/file.pdf");
	 * ---
	 */
	auto setHtmlBody(string body)
	{
		this.htmlBody = validateText("html body", body);
		return this;
	}

	/**
	 * Adds a custom header, e.g. List-Unsubscribe, In-Reply-To, References or X-Mailer.
	 * The same header can be added more than once; headers are written in the order they are added.
	 * Non-ASCII values are encoded according to RFC 2047, which is right for unstructured headers
	 * (X-..., Comments, Keywords): in structured ones (List-Unsubscribe, In-Reply-To, References)
	 * use ASCII only, e.g. percent-encoded URLs.
	 *
	 * The headers that postino writes itself can't be added: MIME-Version, Date, Message-ID,
	 * From, To, Cc, Bcc, Reply-To, Subject and the Content-* headers.
	 *
	 * Params:
	 *     name = Header name, e.g. "List-Unsubscribe"
	 *     value = Header value, without CR or LF
	 *
	 * Returns: Reference to this Email object for method chaining
	 *
	 * Throws: PostinoException if the name is not valid or is reserved, or the value contains CR, LF or NUL
	 *
	 * Example:
	 * ---
	 * email.addHeader("List-Unsubscribe", "<https://example.com/unsubscribe?id=42>, <mailto:unsubscribe@example.com>")
	 *      .addHeader("List-Unsubscribe-Post", "List-Unsubscribe=One-Click");
	 * ---
	 */
	auto addHeader(string name, string value)
	{
		this.headers ~= Header(validateHeaderName(name), validateHeaderValue(name, value));
		return this;
	}

	/**
	 * Embeds a file in the email (inline attachment), to show it in the HTML body
	 * through its Content-ID: `<img src="cid:logo">`.
	 * The file is read when the email is sent or saved.
	 *
	 * Params:
	 *     path = Path to the file to embed
	 *     cid = Content-ID for referencing in HTML (e.g., "logo" for src="cid:logo")
	 *     mimeType = Optional MIME type (detected from the extension if not provided)
	 *
	 * Returns: Reference to this Email object for method chaining
	 *
	 * Throws: PostinoException if path is empty, or cid or mimeType are not valid.
	 *         A missing or unreadable file is reported by send() and save()
	 *
	 * Example:
	 * ---
	 * email.embedFile("/path/to/logo.png", "logo")
	 *      .setHtmlBody("<img src='cid:logo'>");
	 * ---
	 */
	auto embedFile(string path, string cid, string mimeType = string.init)
	{
		if (path.length == 0)
			throw new PostinoException("embedFile: empty path");

		if (mimeType.length == 0)
			mimeType = getMimeType(path);

		this.embeddedFiles[validateContentId(cid)] = Attachment(validateText("file name", baseName(path)), path, null, validateMimeType(mimeType), true);
		return this;
	}

	/**
	 * Embeds data from memory in the email (inline attachment), to show it in the HTML body
	 * through its Content-ID. The data is copied: changing the array afterwards does not change the email.
	 *
	 * Params:
	 *     data = The content, e.g. the bytes of a PNG image
	 *     cid = Content-ID for referencing in HTML (e.g., "chart" for src="cid:chart")
	 *     mimeType = MIME type of the data (e.g., "image/png")
	 *
	 * Returns: Reference to this Email object for method chaining
	 *
	 * Throws: PostinoException if cid or mimeType are not valid
	 *
	 * Example:
	 * ---
	 * email.addEmbeddedFile(png, "chart", "image/png")
	 *      .setHtmlBody("<img src='cid:chart'>");
	 * ---
	 */
	auto addEmbeddedFile(const(ubyte)[] data, string cid, string mimeType)
	{
		if (mimeType.length == 0)
			mimeType = "application/octet-stream";

		this.embeddedFiles[validateContentId(cid)] = Attachment(string.init, string.init, data.idup, validateMimeType(mimeType), false);
		return this;
	}

	/// Old name of embedFile(). A string given here is always read as a file path, never used as data.
	deprecated("use embedFile(path, cid): a string passed to addEmbeddedFile is read as a file path")
	auto addEmbeddedFile(string path, string cid, string mimeType = string.init)
	{
		return embedFile(path, cid, mimeType);
	}

	/**
	 * Attaches a file to the email. Attachments appear as downloadable files in the email client.
	 * The file is read when the email is sent or saved.
	 *
	 * Params:
	 *     path = Path to the file to attach
	 *     mimeType = Optional MIME type (detected from the extension if not provided)
	 *     name = Optional file name shown to the recipient (the base name of path if not provided)
	 *
	 * Returns: Reference to this Email object for method chaining
	 *
	 * Throws: PostinoException if path is empty or mimeType is not valid.
	 *         A missing or unreadable file is reported by send() and save()
	 *
	 * Example:
	 * ---
	 * email.attachFile("/path/to/document.pdf")
	 *      .attachFile("/tmp/export-1234.csv", "text/csv", "orders.csv");
	 * ---
	 */
	auto attachFile(string path, string mimeType = string.init, string name = string.init)
	{
		if (path.length == 0)
			throw new PostinoException("attachFile: empty path");

		if (name.length == 0)
			name = baseName(path);

		if (mimeType.length == 0)
			mimeType = getMimeType(path);

		this.attachments ~= Attachment(validateText("file name", name), path, null, validateMimeType(mimeType), true);
		return this;
	}

	/**
	 * Attaches data from memory to the email. The data is copied: changing the array
	 * afterwards does not change the email. For text, pass `text.representation`
	 * (from std.string).
	 *
	 * Params:
	 *     data = The content of the file
	 *     mimeType = MIME type of the data (detected from the extension of name if empty)
	 *     name = File name shown to the recipient (a random one if not provided)
	 *
	 * Returns: Reference to this Email object for method chaining
	 *
	 * Throws: PostinoException if mimeType or name are not valid
	 *
	 * Example:
	 * ---
	 * import std.string : representation;
	 * email.addAttachment(pdfBytes, "application/pdf", "invoice.pdf")
	 *      .addAttachment(csv.representation, "text/csv", "orders.csv");
	 * ---
	 */
	auto addAttachment(const(ubyte)[] data, string mimeType, string name = string.init)
	{
		import std.uuid : randomUUID;

		if (name.length == 0)
			name = randomUUID().toString();

		if (mimeType.length == 0)
			mimeType = getMimeType(name);

		this.attachments ~= Attachment(validateText("file name", name), string.init, data.idup, validateMimeType(mimeType), false);
		return this;
	}

	/// Old name of attachFile(). A string given here is always read as a file path, never used as data.
	deprecated("use attachFile(path): a string passed to addAttachment is read as a file path")
	auto addAttachment(string path, string mimeType = string.init, string name = string.init)
	{
		return attachFile(path, mimeType, name);
	}

	/// Removes every recipient added with addTo().
	auto clearTo() { this.to = null; return this; }

	/// Removes every recipient added with addCc().
	auto clearCc() { this.cc = null; return this; }

	/// Removes every recipient added with addBcc().
	auto clearBcc() { this.bcc = null; return this; }

	/// Removes every header added with addHeader().
	auto clearHeaders() { this.headers = null; return this; }

	/// Removes every file added with addEmbeddedFile().
	auto clearEmbeddedFiles() { this.embeddedFiles = null; return this; }

	/// Removes every file added with addAttachment().
	auto clearAttachments() { this.attachments = null; return this; }

	/**
	 * Returns a copy of this email, to change it without touching the original:
	 * for example the same message for many recipients, one at a time.
	 * The copy shares the data of the attachments added from memory, so don't modify those arrays.
	 *
	 * Example:
	 * ---
	 * auto newsletter = new Email()
	 *     .setFrom("news@example.com")
	 *     .setSubject("News")
	 *     .setHtmlBody(html);
	 *
	 * auto smtp = SMTP(); // the same SMTP object reuses the connection
	 *
	 * foreach (subscriber; subscribers)
	 *     newsletter.clone()
	 *         .addTo(subscriber.email, subscriber.name)
	 *         .addHeader("List-Unsubscribe", "<https://example.com/unsubscribe?id=" ~ subscriber.id ~ ">")
	 *         .send("smtp://smtp.example.com:587", "user", "password", smtp);
	 * ---
	 */
	Email clone()
	{
		auto copy = new Email();
		copy.from = from;
		copy.to = to.dup;
		copy.cc = cc.dup;
		copy.bcc = bcc.dup;
		copy.replyTo = replyTo;
		copy.subject = subject;
		copy.headers = headers.dup;
		copy.plainTextBody = plainTextBody;
		copy.htmlBody = htmlBody;
		copy.embeddedFiles = embeddedFiles.dup;
		copy.attachments = attachments.dup;
		return copy;
	}

	/**
	 * Sends the email using the specified SMTP server.
	 * The email is delivered to every To, Cc and Bcc recipient.
	 *
	 * Use "smtps://" for implicit TLS (usually port 465) and "smtp://" for
	 * plain SMTP (port 25) or STARTTLS (usually port 587). With "smtp://" and a
	 * username and password, STARTTLS is required, so the credentials never
	 * travel in clear: the server must support it, or send() throws.
	 * Servers on localhost are the exception.
	 *
	 * Pass the same smtp object to many sends to reuse the connection. Each send sets its own
	 * credentials on it, or none: those of a previous send are never reused.
	 *
	 * Params:
	 *     smtpServerUrl = SMTP server URL (e.g., "smtps://smtp.gmail.com:465" or "smtp://smtp.example.com:587")
	 *     username = SMTP authentication username (optional)
	 *     password = SMTP authentication password (optional)
	 *     smtp = Pre-configured SMTP object (optional)
	 *
	 * Returns: true if the email was sent successfully
	 *
	 * Throws: PostinoException if the email has no sender or no recipients, if a file to attach is missing,
	 *         or if the SMTP operation fails (CurlException)
	 *
	 * Example:
	 * ---
	 * email.send("smtps://smtp.gmail.com:465", "user@gmail.com", "app_password");
	 * email.send("smtp://smtp.example.com:587", "user", "password"); // STARTTLS
	 * email.send("smtp://localhost:25"); // No authentication
	 * ---
	 */
	bool send(string smtpServerUrl, string username = string.init, string password = string.init, SMTP smtp = SMTP())
	{
		immutable hasCredentials = username.length > 0 && password.length > 0;

		// A reused SMTP object may hold the credentials or the token of a previous send
		clearCredentials(smtp);

		if (hasCredentials)
			smtp.setAuthentication(username, password);

		return deliver(smtpServerUrl, hasCredentials, smtp);
	}

	/**
	 * Sends the email authenticating with an OAuth 2.0 access token (SASL XOAUTH2),
	 * as Gmail and Microsoft 365 require when passwords are not allowed.
	 * Getting and refreshing the token is up to you; postino only sends it.
	 *
	 * As with the password version, "smtp://" requires STARTTLS, except on localhost.
	 *
	 * Params:
	 *     smtpServerUrl = SMTP server URL (e.g., "smtp://smtp.office365.com:587" or "smtps://smtp.gmail.com:465")
	 *     username = The account the token belongs to, usually its email address
	 *     auth = The OAuth 2.0 access token, as OAuth2(token)
	 *     smtp = Pre-configured SMTP object (optional)
	 *
	 * Returns: true if the email was sent successfully
	 *
	 * Throws: PostinoException if username or the token are empty, if the email has no sender or
	 *         no recipients, or if a file to attach is missing;
	 *         CurlException if the server refuses the token or the SMTP operation fails
	 *
	 * Example:
	 * ---
	 * email.send("smtp://smtp.office365.com:587", "user@example.com", OAuth2(accessToken));
	 * ---
	 */
	bool send(string smtpServerUrl, string username, OAuth2 auth, SMTP smtp = SMTP())
	{
		if (username.length == 0 || auth.accessToken.length == 0)
			throw new PostinoException("OAuth2 needs a username and an access token");

		clearCredentials(smtp);
		smtp.handle.set(CurlOption.username, username);
		smtp.handle.set(curlOptionXOAuth2Bearer, auth.accessToken);

		return deliver(smtpServerUrl, true, smtp);
	}

	/**
	 * Saves the email as a .eml file to the specified path.
	 * The .eml format is a standard email format that can be opened by most email clients.
	 * The file contains exactly the message that send() would deliver: Bcc recipients are not in it.
	 *
	 * Params:
	 *     path = The file path where the .eml file will be saved
	 *
	 * Returns: Reference to this Email object for method chaining
	 *
	 * Throws: PostinoException if the email has no sender or no recipients, if a file to attach is missing,
	 *         or if the file cannot be written to the specified path
	 *
	 * Example:
	 * ---
	 * email.setFrom("sender@example.com")
	 *      .addTo("recipient@example.com")
	 *      .setSubject("Test Email")
	 *      .setPlainTextBody("Hello World!")
	 *      .save("/path/to/email.eml");
	 * ---
	 */
	auto save(string path)
	{
		import std.file : write;
		write(path, build());
		return this;
	}

   private:

	// CURLOPT_XOAUTH2_BEARER, missing from etc.c.curl
	enum curlOptionXOAuth2Bearer = cast(CurlOption)10_220;

	// Forget username, password and token: each send sets its own, or none
	static void clearCredentials(SMTP smtp)
	{
		smtp.handle.clear(CurlOption.userpwd);
		smtp.handle.clear(CurlOption.username);
		smtp.handle.clear(CurlOption.password);
		smtp.handle.clear(curlOptionXOAuth2Bearer);
	}

	bool deliver(string smtpServerUrl, bool hasCredentials, SMTP smtp)
	{
		// Check the URL and build first: nothing is sent if something is wrong
		immutable startTls = requiresStartTls(smtpServerUrl);
		string message = build();

		smtp.url = smtpServerUrl; // sets use_ssl for smtps://

		// Never send credentials in clear: plain smtp:// must upgrade the connection with STARTTLS.
		// Set at every send: a reused SMTP object keeps the value of the previous one.
		if (smtpServerUrl.toLower.startsWith("smtp://"))
			smtp.handle.set(CurlOption.use_ssl, hasCredentials && startTls ? CurlUseSSL.all : CurlUseSSL.none);

		// Envelope recipients: To, Cc and Bcc. Bcc is not written in the headers.
		smtp.mailTo = envelopeRecipients().map!(r => formatEmailOnly(r).to!(const(char)[])).array;
		smtp.mailFrom = formatEmailOnly(from);
		smtp.message = message;

		smtp.perform();
		return true;
	}

	struct Attachment
	{
		string name;
		string path;
		immutable(ubyte)[] data;   // a copy: the caller can't change it afterwards
		string mimeType;
		bool fromFile;
	}

	struct Header
	{
		string name;
		string value;
	}

	struct Recipient
	{
		string address;
		string name;
	}

	// A random boundary that does not appear in the parts it separates, so no content can close a part
	static string randomBoundary(string prefix, string[] parts)
	{
		import std.uuid : randomUUID;
		import std.algorithm.searching : any;

		while (true)
		{
			string boundary = "postino_" ~ prefix ~ "_" ~ randomUUID().toString().replace("-", "") ~ randomUUID().toString().replace("-", "");

			if (!parts.any!(p => p.canFind(boundary)))
				return boundary;
		}
	}

	string build()
	{
		if (from.address.length == 0)
			throw new PostinoException("Missing sender: call setFrom()");

		if (to.length + cc.length + bcc.length == 0)
			throw new PostinoException("Missing recipients: call addTo(), addCc() or addBcc()");

		// Headers. Bcc recipients are never written here, or everyone would see them.
		string result = "MIME-Version: 1.0\r\n";
		result ~= "Date: " ~ formatDate(Clock.currTime) ~ "\r\n";
		result ~= "Message-ID: " ~ messageId() ~ "\r\n";
		result ~= "From: " ~ formatRecipient(from) ~ "\r\n";

		if (to.length > 0)
			result ~= "To: " ~ to.map!(r => formatRecipient(r)).join(",\r\n ") ~ "\r\n";
		else
			result ~= "To: undisclosed-recipients:;\r\n";

		if (cc.length > 0)
			result ~= "Cc: " ~ cc.map!(r => formatRecipient(r)).join(",\r\n ") ~ "\r\n";

		if (replyTo.address.length > 0)
			result ~= "Reply-To: " ~ formatRecipient(replyTo) ~ "\r\n";

		result ~= "Subject: " ~ encodeHeaderText(subject, true) ~ "\r\n";

		foreach (header; headers)
			result ~= header.name ~ ": " ~ encodeHeaderText(header.value) ~ "\r\n";

		// Body: text and html are alternatives, embedded files are related to them,
		// attachments are mixed with all of that.
		string[] alternatives;

		if (plainTextBody.length > 0 || htmlBody.length == 0)
			alternatives ~= buildTextPart("text/plain", plainTextBody);

		if (htmlBody.length > 0)
			alternatives ~= buildTextPart("text/html", htmlBody);

		string content = alternatives.length == 1 ? alternatives[0] : buildMultipart("alternative", alternatives);

		if (embeddedFiles.length > 0) {
			string[] related = [content];

			foreach (cid; embeddedFiles.keys.sort)
				related ~= buildEmbeddedFile(embeddedFiles[cid], cid);

			content = buildMultipart("related", related);
		}

		if (attachments.length > 0) {
			string[] mixed = [content];

			foreach (ref attachment; attachments)
				mixed ~= buildAttachment(attachment);

			content = buildMultipart("mixed", mixed);
		}

		return result ~ content;
	}

	// Everyone who receives the email: To, Cc and Bcc
	Recipient[] envelopeRecipients()
	{
		return to ~ cc ~ bcc;
	}

	// A MIME part (headers, empty line, body) made of other parts
	string buildMultipart(string subtype, string[] parts)
	{
		string boundary = randomBoundary(subtype, parts);
		string result = "Content-Type: multipart/" ~ subtype ~ "; boundary=\"" ~ boundary ~ "\"\r\n\r\n";

		foreach (part; parts)
			result ~= "--" ~ boundary ~ "\r\n" ~ part ~ "\r\n";

		result ~= "--" ~ boundary ~ "--\r\n";
		return result;
	}

	string buildTextPart(string mimeType, string text)
	{
		string result = "Content-Type: " ~ mimeType ~ "; charset=\"UTF-8\"\r\n";
		result ~= "Content-Transfer-Encoding: quoted-printable\r\n\r\n";
		result ~= encodeQuotedPrintable(text);
		return result;
	}

	// Format the recipient address and name
	string formatRecipient(Recipient recipient)
	{
		string cleanAddress = validateEmailAddress(recipient.address);

		if (recipient.name.length > 0) {
			string formattedName = encodeDisplayName(recipient.name);
			return formattedName ~ " <" ~ cleanAddress ~ ">";
		} else {
			return cleanAddress;
		}
	}

	// Encode the display name according to RFC 2047
	string encodeDisplayName(string name)
	{
		string sanitized = sanitizeHeader(name);

		// Check if it contains special characters that require quotes. "=?" too: unquoted, a client
		// would decode it as an encoded-word and show something else (e.g. a fake address)
		bool needsQuotes = sanitized.canFind("=?");
		foreach (char c; sanitized) {
			if (c == '"' || c == '\\' || c == ',' || c == ';' || c == ':' ||
				c == '<' || c == '>' || c == '@' || c == '[' || c == ']' ||
				c == '(' || c == ')' || c == '.') {
				needsQuotes = true;
				break;
			}
		}

		if (hasNonAscii(sanitized)) {
			// Encode RFC 2047 for non-ASCII characters
			return encodeWords(sanitized);
		} else if (needsQuotes) {
			// Escape quotes and backslash, then enclose in quotes
			string escaped = sanitized.replace("\\", "\\\\").replace("\"", "\\\"");
			return "\"" ~ escaped ~ "\"";
		} else {
			return sanitized;
		}
	}

	// Check an email address (addr-spec, without display name) and return it, with an
	// internationalized domain converted to punycode.
	// CR, LF and every other control character are rejected, not removed: a header can't be injected.
	static string validateEmailAddress(string email)
	{
		import std.string : indexOf, split;
		import std.uni : normalize, NFKC, isAlpha, isMark, isNumber, uniToLower = toLower;

		void fail(string reason) { throw new PostinoException("Invalid email address `" ~ sanitizeHeader(email) ~ "`: " ~ reason); }

		if (email.length == 0) fail("empty");

		{
			import std.utf : validate, UTFException;
			try validate(email);
			catch (UTFException) fail("not valid UTF-8");
		}
		if (email.length > 254) fail("longer than 254 characters");

		foreach (char c; email) {
			if (c < 33 || c == 127) fail("contains spaces or control characters");
			if ("()<>[]\\,;:\"".canFind(c)) fail("contains a forbidden character");
		}

		if (email.count('@') != 1) fail("must contain exactly one @");

		immutable at = email.indexOf('@');
		string local = email[0 .. at];
		string domain = email[at + 1 .. $];

		if (local.length == 0 || local.length > 64) fail("the part before @ must be 1 to 64 characters");
		if (local.startsWith(".") || local.endsWith(".") || local.canFind("..")) fail("misplaced dot before @");
		if (hasNonAscii(local)) fail("non-ASCII characters before @ need SMTPUTF8, which postino does not support");

		if (domain.length == 0) fail("missing domain");

		// Internationalized domain (città.it): mapped as browsers and other mailers do (UTS #46):
		// compatibility forms (fullwidth letters, ideographic dots) become their plain form, case is folded
		if (hasNonAscii(domain)) {
			domain = domain.normalize!NFKC.uniToLower.normalize!NFKC.replace("\u3002", ".");

			foreach (char c; domain)
				if (c < 33 || c == 127 || "()<>[]\\,;:\"@".canFind(c))
					fail("the domain contains a forbidden character");
		}

		string[] labels = domain.split(".");

		foreach (ref label; labels) {
			if (label.length == 0) fail("empty label in domain");

			// Written as punycode (xn--citt-3na.it). Only letters, digits, marks and - are allowed:
			// invisible characters (soft hyphen, zero width space, ...) would make a domain that looks like another
			if (hasNonAscii(label)) {
				foreach (dchar c; label)
					if (!isAlpha(c) && !isMark(c) && !isNumber(c) && c != '-')
						fail("the domain contains a character that is not allowed (invisible or a symbol)");

				label = "xn--" ~ punycode(label.to!dstring);
			}

			if (label.length > 63) fail("domain label longer than 63 characters");
			if (label.startsWith("-") || label.endsWith("-")) fail("domain label starts or ends with -");
		}

		string result = local ~ "@" ~ labels.join(".");

		if (result.length > 254) fail("longer than 254 characters once the domain is converted");

		return result;
	}

	// Punycode encoding of a domain label (RFC 3492), without the xn-- prefix
	static string punycode(dstring input)
	{
		enum uint base = 36, tmin = 1, tmax = 26, skew = 38, damp = 700;

		char digit(uint d) { return cast(char)(d < 26 ? 'a' + d : '0' + d - 26); }

		uint adapt(uint delta, uint numPoints, bool first)
		{
			delta = first ? delta / damp : delta / 2;
			delta += delta / numPoints;

			uint k = 0;
			while (delta > ((base - tmin) * tmax) / 2) {
				delta /= base - tmin;
				k += base;
			}

			return k + (base - tmin + 1) * delta / (delta + skew);
		}

		// Basic (ASCII) code points first, then a "-" if there are any
		string output = "";
		foreach (c; input)
			if (c < 0x80)
				output ~= cast(char)c;

		uint handled = cast(uint)output.length;
		immutable uint basic = handled;

		if (basic > 0)
			output ~= '-';

		uint n = 0x80, delta = 0, bias = 72;

		while (handled < input.length)
		{
			uint m = uint.max;
			foreach (c; input)
				if (c >= n && c < m)
					m = c;

			delta += (m - n) * (handled + 1);
			n = m;

			foreach (c; input)
			{
				if (c < n) delta++;
				if (c != n) continue;

				uint q = delta;
				for (uint k = base; ; k += base)
				{
					immutable uint t = k <= bias ? tmin : (k >= bias + tmax ? tmax : k - bias);
					if (q < t) break;
					output ~= digit(t + (q - t) % (base - t));
					q = (q - t) / (base - t);
				}

				output ~= digit(q);
				bias = adapt(delta, handled + 1, handled == basic);
				delta = 0;
				handled++;
			}

			delta++;
			n++;
		}

		return output;
	}

	// Header name: printable ASCII without ":" (RFC 5322), not one of those written by postino
	static string validateHeaderName(string name)
	{
		static immutable reserved = ["mime-version", "date", "message-id", "from", "to", "cc", "bcc", "reply-to", "subject"];

		if (name.length == 0)
			throw new PostinoException("Invalid header name: empty");

		foreach (char c; name)
			if (c < 33 || c > 126 || c == ':')
				throw new PostinoException("Invalid header name `" ~ sanitizeHeader(name) ~ "`: use letters, digits and -");

		immutable lower = name.toLower;

		if (reserved.canFind(lower) || lower.startsWith("content-"))
			throw new PostinoException("Header `" ~ name ~ "` is written by postino: use its own setter");

		return name;
	}

	// Header value: no CR, LF or NUL, and not longer than a header line can be
	static string validateHeaderValue(string name, string value)
	{
		foreach (char c; value)
			if ((c < 32 && c != '\t') || c == 127)
				throw new PostinoException("Invalid value for header `" ~ name ~ "`: it contains CR, LF or other control characters");

		validateText("value for header `" ~ name ~ "`", value);

		if (!hasNonAscii(value) && name.length + 2 + value.length > 998)
			throw new PostinoException("Header `" ~ name ~ "` is longer than 998 characters");

		return value;
	}

	// Content-ID of an embedded file: printable ASCII, no spaces and no <>
	static string validateContentId(string cid)
	{
		if (cid.length == 0)
			throw new PostinoException("Invalid Content-ID: empty");

		foreach (char c; cid)
			if (c < 33 || c > 126 || "<>()[]\\,;:\"".canFind(c))
				throw new PostinoException("Invalid Content-ID `" ~ sanitizeHeader(cid) ~ "`: use letters, digits and .-_@");

		return cid;
	}

	// MIME type as type/subtype, made of RFC 2045 token characters
	static string validateMimeType(string mimeType)
	{
		import std.string : split;

		bool isToken(string s)
		{
			if (s.length == 0) return false;

			foreach (char c; s)
				if (c < 33 || c > 126 || "()<>@,;:\\\"/[]?=".canFind(c))
					return false;

			return true;
		}

		auto parts = mimeType.split("/");

		if (parts.length != 2 || !isToken(parts[0]) || !isToken(parts[1]))
			throw new PostinoException("Invalid MIME type `" ~ sanitizeHeader(mimeType) ~ "`: expected type/subtype, e.g. image/png");

		return mimeType;
	}

	const(ubyte)[] readAttachmentData(ref Attachment attachment)
	{
		import std.file : isDir, FileException;

		// Data given directly
		if (!attachment.fromFile)
			return attachment.data;

		// Read from file
		if (!exists(attachment.path))
			throw new PostinoException("File not found: " ~ attachment.path);

		if (isDir(attachment.path))
			throw new PostinoException("Not a file: " ~ attachment.path);

		try return cast(const(ubyte)[])read(attachment.path);
		catch (FileException e) throw new PostinoException("Can't read " ~ attachment.path ~ ": " ~ e.msg);
	}

	string encodeBase64Lines(const(ubyte)[] data)
	{
		string result = "";

		// Divide in lines of 76 characters as per RFC standard
		foreach(line; Base64.encode(data).chunks(76))
			result ~= line.to!string ~ "\r\n";

		return result;
	}

	string buildEmbeddedFile(ref Attachment attachment, string contentId)
	{
		string result = "";

		result ~= "Content-Type: " ~ attachment.mimeType ~ "\r\n";
		result ~= "Content-ID: <" ~ contentId ~ ">\r\n";

		if (attachment.name.length > 0)
			result ~= "Content-Disposition: inline;" ~ filenameParameters(attachment.name) ~ "\r\n";
		else
			result ~= "Content-Disposition: inline\r\n";

		result ~= "Content-Transfer-Encoding: base64\r\n\r\n";
		result ~= encodeBase64Lines(readAttachmentData(attachment));
		return result;
	}

	string buildAttachment(ref Attachment attachment)
	{
		string result = "";

		result ~= "Content-Type: " ~ attachment.mimeType ~ "\r\n";
		result ~= "Content-Disposition: attachment;" ~ filenameParameters(attachment.name) ~ "\r\n";
		result ~= "Content-Transfer-Encoding: base64\r\n\r\n";
		result ~= encodeBase64Lines(readAttachmentData(attachment));
		return result;
	}

	// filename="..." for every client and, if the name is not ASCII, filename*=UTF-8''... (RFC 2231)
	string filenameParameters(string fileName)
	{
		string sanitized = sanitizeHeader(fileName);
		string ascii = "";

		foreach (dchar c; sanitized)
			ascii ~= (c > 126 || c < 32) ? '_' : cast(char)c;

		// Escape backslash first, then quotes: the other way round doubles the escapes
		string result = "\r\n filename=\"" ~ ascii.replace("\\", "\\\\").replace("\"", "\\\"") ~ "\"";

		// filename* first: parsers that read only one of the two take the first
		if (hasNonAscii(sanitized))
			result = "\r\n filename*=UTF-8''" ~ percentEncode(sanitized) ~ ";" ~ result;

		return result;
	}

	// RFC 2231 value: attr-chars as they are, every other byte as %XX
	static string percentEncode(string text)
	{
		string result = "";

		foreach (char c; text)
		{
			if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || "!#$&+-.^_`|~".canFind(c))
				result ~= c;
			else
				result ~= format("%%%02X", cast(ubyte)c);
		}

		return result;
	}

	string getMimeType(string filePath)
	{
		immutable mimes =
		[
			// Text/document formats
			".html" : "text/html", ".htm" : "text/html", ".shtml" : "text/html", ".css" : "text/css", ".xml" : "text/xml",
			".txt" : "text/plain", ".md" : "text/markdown", ".csv" : "text/csv", ".yaml" : "text/yaml", ".yml" : "text/yaml",
			".jad" : "text/vnd.sun.j2me.app-descriptor", ".wml" : "text/vnd.wap.wml", ".htc" : "text/x-component",

			// Image formats
			".gif" : "image/gif", ".jpeg" : "image/jpeg", ".jpg" : "image/jpeg", ".png" : "image/png",
			".tif" : "image/tiff", ".tiff" : "image/tiff", ".wbmp" : "image/vnd.wap.wbmp",
			".ico" : "image/x-icon", ".jng" : "image/x-jng", ".bmp" : "image/x-ms-bmp",
			".svg" : "image/svg+xml", ".svgz" : "image/svg+xml", ".webp" : "image/webp",
			".avif" : "image/avif", ".heic" : "image/heic", ".heif" : "image/heif", ".jxl" : "image/jxl",

			// Web fonts
			".woff" : "application/font-woff", ".woff2": "font/woff2", ".ttf" : "font/ttf", ".otf" : "font/otf",
			".eot" : "application/vnd.ms-fontobject",

			// Archives and applications
			".jar" : "application/java-archive", ".war" : "application/java-archive", ".ear" : "application/java-archive",
			".json" : "application/json", ".hqx" : "application/mac-binhex40", ".doc" : "application/msword",
			".pdf" : "application/pdf", ".ps" : "application/postscript", ".eps" : "application/postscript",
			".ai" : "application/postscript", ".rtf" : "application/rtf", ".m3u8" : "application/vnd.apple.mpegurl",
			".xls" : "application/vnd.ms-excel", ".ppt" : "application/vnd.ms-powerpoint", ".wmlc" : "application/vnd.wap.wmlc",
			".kml" : "application/vnd.google-earth.kml+xml", ".kmz" : "application/vnd.google-earth.kmz",
			".7z" : "application/x-7z-compressed", ".cco" : "application/x-cocoa",
			".jardiff" : "application/x-java-archive-diff", ".jnlp" : "application/x-java-jnlp-file",
			".run" : "application/x-makeself", ".pl" : "application/x-perl", ".pm" : "application/x-perl",
			".prc" : "application/x-pilot", ".pdb" : "application/x-pilot", ".rar" : "application/x-rar-compressed",
			".rpm" : "application/x-redhat-package-manager", ".sea" : "application/x-sea",
			".swf" : "application/x-shockwave-flash", ".sit" : "application/x-stuffit", ".tcl" : "application/x-tcl",
			".tk" : "application/x-tcl", ".der" : "application/x-x509-ca-cert", ".pem" : "application/x-x509-ca-cert",
			".crt" : "application/x-x509-ca-cert", ".xpi" : "application/x-xpinstall", ".xhtml" : "application/xhtml+xml",
			".xspf" : "application/xspf+xml", ".zip" : "application/zip",
			".br" : "application/x-brotli", ".gz" : "application/gzip",
			".bz2" : "application/x-bzip2", ".xz" : "application/x-xz",

			// Generic binary files
			".bin" : "application/octet-stream", ".exe" : "application/octet-stream", ".dll" : "application/octet-stream",
			".deb" : "application/octet-stream", ".dmg" : "application/octet-stream", ".iso" : "application/octet-stream",
			".img" : "application/octet-stream", ".msi" : "application/octet-stream", ".msp" : "application/octet-stream",
			".msm" : "application/octet-stream",

			// Office documents
			".docx" : "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
			".xlsx" : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
			".pptx" : "application/vnd.openxmlformats-officedocument.presentationml.presentation",

			// Audio formats
			".mid" : "audio/midi", ".midi" : "audio/midi", ".kar" : "audio/midi",
			".mp3" : "audio/mpeg", ".ogg" : "audio/ogg", ".m4a" : "audio/x-m4a",
			".ra" : "audio/x-realaudio", ".opus" : "audio/opus", ".aac" : "audio/aac",
			".flac" : "audio/flac",

			// Video
			".3gpp" : "video/3gpp", ".3gp" : "video/3gpp", ".ts" : "video/mp2t", ".mp4" : "video/mp4",
			".mpeg" : "video/mpeg", ".mpg" : "video/mpeg", ".mov" : "video/quicktime",
			".webm" : "video/webm", ".flv" : "video/x-flv", ".m4v" : "video/x-m4v",
			".mng" : "video/x-mng", ".asx" : "video/x-ms-asf", ".asf" : "video/x-ms-asf",
			".wmv" : "video/x-ms-wmv", ".avi" : "video/x-msvideo",
			".mkv" : "video/x-matroska", ".ogv" : "video/ogg",

			// Web development
			".js" : "application/javascript", ".wasm" : "application/wasm",
			".atom" : "application/atom+xml", ".rss" : "application/rss+xml",
			".mml" : "text/mathml"
		];

		if (auto mime = filePath.extension.toLower in mimes)
			return *mime;

		return "application/octet-stream";
	}

	// Remove the control characters (CR, LF, NUL, ESC, ...) but tab: they could break or hide headers
	static string sanitizeHeader(string input)
	{
		string result = "";

		foreach (char c; input)
			if ((c >= 32 && c != 127) || c == '\t')
				result ~= c;

		return result;
	}

	// Text must be valid UTF-8: it is declared as such in the message
	static string validateText(string what, string text)
	{
		import std.utf : validate, UTFException;

		try validate(text);
		catch (UTFException) throw new PostinoException("Invalid " ~ what ~ ": not valid UTF-8");

		return text;
	}

	static bool hasNonAscii(string s)
	{
		foreach (char c; s)
			if (c > 127)
				return true;

		return false;
	}

	// Text for a header: RFC 2047 if it contains non-ASCII characters, or "=?" that a client would
	// decode as an encoded-word. With fold, long ASCII text is folded at spaces (the subject).
	string encodeHeaderText(string text, bool fold = false)
	{
		string sanitized = sanitizeHeader(text);

		if (hasNonAscii(sanitized) || sanitized.canFind("=?"))
			return encodeWords(sanitized);

		if (fold && sanitized.length > 70)
			return foldText(sanitized);

		return sanitized;
	}

	// Long ASCII text on more lines, breaking at spaces (RFC 5322 2.2.3): unfolding gives the text back.
	// A word too long for a line (998 characters) is encoded instead.
	string foldText(string text)
	{
		string[] lines = [""];

		foreach (i, word; text.split(" "))
		{
			if (word.length > 900)
				return encodeWords(text);

			if (i == 0)
				lines[$ - 1] = word;
			else if (lines[$ - 1].length + 1 + word.length > 70 && lines[$ - 1].strip.length > 0)
				lines ~= " " ~ word;
			else
				lines[$ - 1] ~= " " ~ word;
		}

		return lines.join("\r\n");
	}

	// RFC 2047 encoded-words of at most 75 characters each, on folded lines,
	// never splitting a UTF-8 character between two words.
	string encodeWords(string text)
	{
		enum maxBytes = 39; // 52 base64 characters, 64 with =?UTF-8?B? and ?=: "Subject: " fits in 76

		string[] words;
		size_t start = 0;

		while (start < text.length)
		{
			size_t end = start;

			while (end < text.length)
			{
				immutable len = stride(text, end);
				if (end + len - start > maxBytes) break;
				end += len;
			}

			words ~= "=?UTF-8?B?" ~ Base64.encode(cast(const(ubyte)[])text[start .. end]).to!string ~ "?=";
			start = end;
		}

		return words.join("\r\n ");
	}

	// Quoted-printable (RFC 2045): CRLF line endings and lines of at most 76 characters,
	// whatever the line length or the characters of the text.
	static string encodeQuotedPrintable(string text)
	{
		// Only CRLF, LF and CR end a line: VT, FF, NEL, U+2028 and U+2029 are content, encoded as they are
		auto lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n");

		// A final line break does not start another line
		if (lines.length > 0 && lines[$ - 1].length == 0)
			lines = lines[0 .. $ - 1];

		string result = "";

		foreach (line; lines)
		{
			string encodedLine = "";
			size_t lineLength = 0;

			foreach (i, char c; line)
			{
				string encoded;
				immutable isLast = i == line.length - 1;

				if ((c >= 33 && c <= 126 && c != '=') || ((c == ' ' || c == '\t') && !isLast))
					encoded = [c];
				else
					encoded = format("=%02X", cast(ubyte)c);

				// Soft line break: "=" at the end of a line is not part of the text
				if (lineLength + encoded.length > (isLast ? 76 : 75)) {
					encodedLine ~= "=\r\n";
					lineLength = 0;
				}

				encodedLine ~= encoded;
				lineLength += encoded.length;
			}

			result ~= encodedLine ~ "\r\n";
		}

		return result;
	}

	string formatEmailOnly(Recipient recipient)
	{
		return "<" ~ validateEmailAddress(recipient.address) ~ ">";
	}

	// Date in RFC 5322 format, e.g. "Fri, 06 Nov 2026 14:05:09 +0100"
	static string formatDate(SysTime time)
	{
		static immutable days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
		static immutable months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

		immutable offset = time.utcOffset.total!"minutes";
		immutable absOffset = offset < 0 ? -offset : offset;

		return format("%s, %02d %s %04d %02d:%02d:%02d %s%02d%02d",
			days[time.dayOfWeek], time.day, months[time.month - 1], time.year,
			time.hour, time.minute, time.second,
			offset < 0 ? "-" : "+", absOffset / 60, absOffset % 60);
	}

	// Unique Message-ID with the domain of the sender
	string messageId()
	{
		import std.uuid : randomUUID;
		import std.string : indexOf;

		string domain = from.address[from.address.indexOf('@') + 1 .. $];
		return "<" ~ randomUUID().toString() ~ "@" ~ domain ~ ">";
	}

	// The host of an SMTP URL, after checking the URL. Credentials, query and fragment are refused:
	// libcurl would read credentials from the URL and send them without the STARTTLS check,
	// and "?" or "#" followed by "@" would make the host here differ from the one libcurl connects to.
	static string smtpHost(string smtpServerUrl)
	{
		import std.string : indexOf;

		string url = smtpServerUrl.toLower;
		string rest;

		if (url.startsWith("smtp://")) rest = url["smtp://".length .. $];
		else if (url.startsWith("smtps://")) rest = url["smtps://".length .. $];
		else throw new PostinoException("Invalid SMTP URL: it must start with smtp:// or smtps://");

		foreach (char c; url)
			if (c < 33 || c == 127)
				throw new PostinoException("Invalid SMTP URL: it contains spaces or control characters");

		if (url.canFind('?') || url.canFind('#'))
			throw new PostinoException("Invalid SMTP URL: ? and # are not allowed");

		auto slash = rest.indexOf('/');
		string authority = slash >= 0 ? rest[0 .. slash] : rest;

		if (authority.canFind('@'))
			throw new PostinoException("Invalid SMTP URL: don't put credentials in the URL, pass them to send()");

		string host;

		if (authority.startsWith("[")) {
			auto close = authority.indexOf(']');
			if (close < 0) throw new PostinoException("Invalid SMTP URL: missing ]");
			host = authority[1 .. close];
		} else {
			auto colon = authority.indexOf(':');
			host = colon >= 0 ? authority[0 .. colon] : authority;
		}

		if (host.length == 0)
			throw new PostinoException("Invalid SMTP URL: missing host");

		return host;
	}

	// localhost, or an IP address of this machine's loopback: 127.0.0.0/8 or ::1.
	// Names are not resolved: 127.example.com is not local.
	static bool isLoopback(string host)
	{
		import std.socket : InternetAddress, Internet6Address;

		static immutable ubyte[16] loopback6 = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1];

		if (host == "localhost")
			return true;

		// An IPv4 address (in host byte order), or ADDR_NONE if host is not one
		immutable v4 = InternetAddress.parse(host);
		if (v4 != InternetAddress.ADDR_NONE)
			return (v4 >> 24) == 127;

		try return Internet6Address.parse(host) == loopback6;
		catch (Exception) return false;
	}

	// With smtp:// and credentials STARTTLS is required, unless the server is on this machine
	static bool requiresStartTls(string smtpServerUrl)
	{
		// smtpHost first: it checks the URL, smtps:// included
		immutable host = smtpHost(smtpServerUrl);
		return smtpServerUrl.toLower.startsWith("smtp://") && !isLoopback(host);
	}

	Attachment[string] embeddedFiles;
	Attachment[] attachments;

	Recipient from;
	Recipient[] to;
	string subject;
	Recipient[] cc;
	Recipient[] bcc;
	Recipient replyTo;
	Header[] headers;

	string plainTextBody;
	string htmlBody;

}

version(unittest)
{
	import std.file : tempDir, remove, readText, write;
	import std.array : split, replicate;
	import std.algorithm : filter, countUntil, any;
	import std.exception : collectExceptionMsg;
	import std.string : representation;
	import core.atomic : atomicLoad;
	import std.path : buildPath;
	import std.string : indexOf, splitLines;
	import std.exception : assertThrown, assertNotThrown;

	// Headers of a message: everything before the first empty line
	string headersOf(string message)
	{
		return message[0 .. message.indexOf("\r\n\r\n") + 2];
	}

	// An address of this machine that is not loopback: postino treats it as a remote server.
	// It is the address used to reach the internet; no packet is sent to find it.
	string remoteTestHost()
	{
		import std.socket : UdpSocket, InternetAddress;

		try {
			auto socket = new UdpSocket();
			scope(exit) socket.close();
			socket.connect(new InternetAddress("192.0.2.1", 9));
			return socket.localAddress.toAddrString;
		}
		catch (Exception) return "0.0.0.0"; // no network: on Linux and macOS 0.0.0.0 reaches this machine
	}

	string tempFile(string name)
	{
		import std.uuid : randomUUID;
		return buildPath(tempDir, "postino-test-" ~ randomUUID().toString() ~ "-" ~ name);
	}
}

// Cc and Bcc receive the email, Bcc is not in the headers
unittest
{
	auto email = new Email()
		.setFrom("sender@example.com", "Sender")
		.addTo("to@example.com", "To")
		.addCc("cc@example.com")
		.addBcc("hidden@example.com", "Hidden")
		.setSubject("Hello")
		.setPlainTextBody("Hi");

	assert(email.envelopeRecipients().map!(r => email.formatEmailOnly(r)).array
		== ["<to@example.com>", "<cc@example.com>", "<hidden@example.com>"]);

	string path = tempFile("bcc.eml");
	scope(exit) remove(path);
	email.save(path);

	string message = readText(path);
	assert(!message.canFind("hidden@example.com"));
	assert(!message.canFind("Hidden"));
	assert(!message.canFind("Bcc:"));
	assert(headersOf(message).canFind("\r\nCc: cc@example.com\r\n"));
	assert(headersOf(message).canFind("\r\nTo: To <to@example.com>\r\n"));
}

// Only Bcc recipients: an empty group in To, not an empty header
unittest
{
	string message = new Email()
		.setFrom("sender@example.com")
		.addBcc("hidden@example.com")
		.setPlainTextBody("Hi")
		.build();

	assert(headersOf(message).canFind("\r\nTo: undisclosed-recipients:;\r\n"));
	assert(!message.canFind("hidden@example.com"));
}

// Sender and recipients are required, send() checks them before connecting
unittest
{
	import std.exception : collectExceptionMsg;

	assertThrown(new Email().addTo("to@example.com").build());
	assertThrown(new Email().setFrom("sender@example.com").build());

	assert(collectExceptionMsg(new Email().addTo("to@example.com").send("smtp://localhost:1")).startsWith("Missing sender"));
	assert(collectExceptionMsg(new Email().setFrom("sender@example.com").send("smtp://localhost:1")).startsWith("Missing recipients"));
}

// Date and Message-ID
unittest
{
	import std.datetime : DateTime, TimeZone, SimpleTimeZone;
	import core.time : hours, minutes;

	string headers = headersOf(new Email().setFrom("a@example.com").addTo("b@example.com").build());
	assert(headers.canFind("\r\nDate: "));
	assert(headers.canFind("\r\nMessage-ID: <") && headers.canFind("@example.com>\r\n"));

	auto time = SysTime(DateTime(2026, 11, 6, 14, 5, 9), new immutable SimpleTimeZone(1.hours));
	assert(Email.formatDate(time) == "Fri, 06 Nov 2026 14:05:09 +0100");

	time = SysTime(DateTime(2026, 1, 1, 0, 0, 0), new immutable SimpleTimeZone(-(3.hours + 30.minutes)));
	assert(Email.formatDate(time) == "Thu, 01 Jan 2026 00:00:00 -0330");
}

// Invalid addresses are rejected as soon as they are added
unittest
{
	auto email = new Email();

	foreach (bad; [
		"", "plain", "a@b@c.com", "@example.com", "user@", "user@.com", "user@example..com",
		".user@example.com", "user.@example.com", "us..er@example.com", "user@-example.com",
		"user name@example.com", "user@example.com\r\nBcc: evil@example.com", "user@example.com\nX: y",
		"<user@example.com>", "\"user\"@example.com", "user@example.com,other@example.com",
		"user@exa\0mple.com"
	])
	{
		assertThrown(email.addTo(bad), bad);
		assertThrown(email.addCc(bad), bad);
		assertThrown(email.addBcc(bad), bad);
		assertThrown(email.setFrom(bad), bad);
		assertThrown(email.setReplyTo(bad), bad);
	}

	foreach (good; ["user@example.com", "first.last+tag@sub.example.co.uk", "x@localhost", "o'brien@example.com"])
		assertNotThrown(email.addTo(good), good);
}

// CR and LF in subject and names can't inject headers
unittest
{
	string message = new Email()
		.setFrom("sender@example.com", "Evil\r\nBcc: victim@example.com")
		.addTo("to@example.com", "Name\nX-Injected: yes")
		.setSubject("Hello\r\nBcc: victim@example.com\r\n\r\nfake body")
		.setPlainTextBody("Hi")
		.build();

	foreach (line; headersOf(message).splitLines)
		assert(!line.startsWith("Bcc:") && !line.startsWith("X-Injected:"), line);

	assert(headersOf(message).canFind("\r\nSubject: HelloBcc: victim@example.comfake body\r\n"));
}

// Content-ID and MIME type are checked, the given MIME type is used
unittest
{
	auto email = new Email();

	assertThrown(email.addEmbeddedFile(cast(ubyte[])"x", "id\r\nX-Injected: yes", "image/png"));
	assertThrown(email.addEmbeddedFile(cast(ubyte[])"x", "<id>", "image/png"));
	assertThrown(email.addEmbeddedFile(cast(ubyte[])"x", "", "image/png"));
	assertThrown(email.addEmbeddedFile(cast(ubyte[])"x", "id", "image/png\r\nX-Injected: yes"));
	assertThrown(email.addAttachment(cast(ubyte[])"x", "text"));
	assertThrown(email.attachFile("file.txt", "text/plain; charset=utf-8"));

	string path = tempFile("data.bin");
	write(path, "data");
	scope(exit) remove(path);

	string message = email
		.setFrom("sender@example.com")
		.addTo("to@example.com")
		.setHtmlBody("<img src='cid:logo'>")
		.embedFile(path, "logo", "image/png")
		.attachFile(path, "application/x-custom", "custom.bin")
		.build();

	assert(message.canFind("Content-Type: image/png\r\nContent-ID: <logo>\r\n"));
	assert(message.canFind("Content-Type: application/x-custom\r\n"));
}

// MIME structure: alternative, related and mixed, only when needed
unittest
{
	auto email = new Email().setFrom("sender@example.com").addTo("to@example.com");

	string message = email.setPlainTextBody("Hi").build();
	assert(headersOf(message).canFind("Content-Type: text/plain; charset=\"UTF-8\"\r\n"));
	assert(!message.canFind("multipart/"));

	message = email.setHtmlBody("<b>Hi</b>").build();
	assert(headersOf(message).canFind("Content-Type: multipart/alternative;"));

	message = email.addEmbeddedFile(cast(ubyte[])"png", "logo", "image/png").build();
	assert(headersOf(message).canFind("Content-Type: multipart/related;"));

	message = email.addAttachment(cast(ubyte[])"pdf", "application/pdf", "doc.pdf").build();
	assert(headersOf(message).canFind("Content-Type: multipart/mixed;"));
	assert(message.canFind("Content-Type: multipart/related;"));
	assert(message.canFind("Content-Type: multipart/alternative;"));
	assert(message.canFind("Content-Disposition: attachment;\r\n filename=\"doc.pdf\"\r\n"));
	assert(message.canFind(Base64.encode(cast(ubyte[])"pdf")));
}

// A missing file is an error, not an empty attachment
unittest
{
	auto email = new Email()
		.setFrom("sender@example.com")
		.addTo("to@example.com")
		.attachFile("/nonexistent/postino/report.pdf");

	assertThrown(email.build());
	assertThrown(email.save(tempFile("never.eml")));
}

// File names: quotes and backslashes escaped, non-ASCII names in filename*
unittest
{
	string message = new Email()
		.setFrom("sender@example.com")
		.addTo("to@example.com")
		.addAttachment(cast(ubyte[])"x", "text/plain", "a\"b\\c.txt")
		.addAttachment(cast(ubyte[])"x", "text/plain", "perché è così.txt")
		.addAttachment(cast(ubyte[])"x", "text/plain", "evil\r\nX-Injected: yes.txt")
		.build();

	assert(message.canFind(`filename="a\"b\\c.txt"`));
	assert(message.canFind("filename*=UTF-8''perch%C3%A9%20%C3%A8%20cos%C3%AC.txt;\r\n filename=\"perch_ _ cos_.txt\""));
	assert(!message.canFind("\r\nX-Injected"));
}

// Non-ASCII subject and names: RFC 2047 encoded-words of at most 75 characters
unittest
{
	string subject = "Città, perché è così? ";
	foreach (i; 0 .. 5) subject ~= subject;

	auto email = new Email()
		.setFrom("sender@example.com", "Andrè")
		.addTo("to@example.com")
		.setSubject(subject)
		.setPlainTextBody("Hi");

	string headers = headersOf(email.build());
	assert(headers.canFind("\r\nFrom: =?UTF-8?B?" ~ Base64.encode(cast(ubyte[])"Andrè") ~ "?= <sender@example.com>\r\n"));

	string decoded = "";
	bool inSubject = false;

	foreach (line; headers.splitLines)
	{
		assert(line.length <= 78, line);

		if (line.startsWith("Subject: ")) { inSubject = true; line = line["Subject: ".length .. $]; }
		else if (!line.startsWith(" ")) inSubject = false;

		if (!inSubject) continue;

		line = line.startsWith(" ") ? line[1 .. $] : line;
		assert(line.startsWith("=?UTF-8?B?") && line.endsWith("?=") && line.length <= 75);
		decoded ~= cast(string)Base64.decode(line[10 .. $ - 2]);
	}

	// Each word is valid UTF-8 on its own and the whole subject is there
	assert(decoded == subject);
}

// Quoted-printable body: CRLF, short lines, non-ASCII and = encoded
unittest
{
	assert(Email.encodeQuotedPrintable("a=b") == "a=3Db\r\n");
	assert(Email.encodeQuotedPrintable("è") == "=C3=A8\r\n");
	assert(Email.encodeQuotedPrintable("one\ntwo\r\nthree") == "one\r\ntwo\r\nthree\r\n");
	assert(Email.encodeQuotedPrintable("trailing space ") == "trailing space=20\r\n");

	string longLine = "";
	foreach (i; 0 .. 500) longLine ~= "è<a href=\"x\">";

	string encoded = Email.encodeQuotedPrintable(longLine);

	foreach (line; encoded.splitLines)
		assert(line.length <= 76, line);

	// Decode it back
	string decoded = "";
	foreach (line; encoded.splitLines)
	{
		bool soft = line.endsWith("=");
		if (soft) line = line[0 .. $ - 1];

		for (size_t i = 0; i < line.length; i++)
		{
			if (line[i] == '=') { decoded ~= cast(char)line[i + 1 .. i + 3].to!ubyte(16); i += 2; }
			else decoded ~= line[i];
		}
	}

	assert(decoded == longLine);
}

// STARTTLS is required for smtp:// with credentials, except on this machine
unittest
{
	assert(Email.requiresStartTls("smtp://smtp.example.com:587"));
	assert(Email.requiresStartTls("SMTP://smtp.example.com"));
	assert(Email.requiresStartTls("smtp://smtp.example.com:587/client.example.com"));
	assert(Email.requiresStartTls("smtp://[2001:db8::1]:587"));

	assert(!Email.requiresStartTls("smtps://smtp.example.com:465"));
	assert(!Email.requiresStartTls("smtp://localhost:25"));
	assert(!Email.requiresStartTls("smtp://127.0.0.1:1025"));
	assert(!Email.requiresStartTls("smtp://[::1]:25"));
}

// save() writes the same message that send() delivers
unittest
{
	string path = tempFile("full.eml");
	scope(exit) remove(path);

	new Email()
		.setFrom("sender@example.com", "Sender")
		.addTo("to@example.com")
		.setReplyTo("reply@example.com")
		.setSubject("Report")
		.setPlainTextBody("See attachment")
		.addAttachment(cast(ubyte[])"%PDF", "application/pdf", "report.pdf")
		.save(path);

	string message = readText(path);
	assert(message.startsWith("MIME-Version: 1.0\r\n"));
	assert(headersOf(message).canFind("\r\nReply-To: reply@example.com\r\n"));
	assert(headersOf(message).canFind("\r\nSubject: Report\r\n"));
	assert(message.endsWith("--\r\n"));

	// Every line ends with CRLF and is short
	foreach (line; message.split("\r\n"))
		assert(!line.canFind("\n") && !line.canFind("\r") && line.length <= 998);
}

version(unittest)
{
	// A minimal SMTP server on 127.0.0.1, in a thread: it records the commands it receives
	// and the number of connections. Enough to test what postino and libcurl send.
	class FakeSmtpServer
	{
		import std.socket : TcpSocket, Socket, InternetAddress, SocketShutdown;
		import core.thread : Thread;
		import core.sync.mutex : Mutex;

		ushort port;
		shared int connections;

		// On 127.0.0.1 by default; on 0.0.0.0 (every interface) to be reached as a remote host too
		this(string bindAddress = "127.0.0.1")
		{
			listener = new TcpSocket();
			listener.bind(new InternetAddress(bindAddress, 0));
			listener.listen(5);
			port = (cast(InternetAddress)listener.localAddress).port;
			mutex = new Mutex();
			thread = new Thread(&run);
			thread.isDaemon = true;
			thread.start();
		}

		string[] commands()
		{
			mutex.lock(); scope(exit) mutex.unlock();
			return log.dup;
		}

		void stop()
		{
			listener.shutdown(SocketShutdown.BOTH);
			listener.close();
		}

	private:

		TcpSocket listener;
		Thread thread;
		Mutex mutex;
		string[] log;

		void record(string line)
		{
			mutex.lock(); scope(exit) mutex.unlock();
			log ~= line;
		}

		void run()
		{
			import core.atomic : atomicOp;

			while (true)
			{
				Socket client;
				try client = listener.accept();
				catch (Exception) return;

				connections.atomicOp!"+="(1);

				// One thread per connection: libcurl keeps a connection open while it opens another
				auto worker = new Thread(serveAndClose(client));
				worker.isDaemon = true;
				worker.start();
			}
		}

		void delegate() serveAndClose(Socket client)
		{
			return () {
				try serve(client);
				catch (Exception) {}
				client.close();
			};
		}

		void serve(Socket client)
		{
			import std.string : indexOf, toUpper;

			string buffer;

			string readLine()
			{
				while (buffer.indexOf("\r\n") < 0)
				{
					char[1024] chunk;
					auto n = client.receive(chunk[]);
					if (n <= 0) return null;
					buffer ~= chunk[0 .. n].idup;
				}

				auto end = buffer.indexOf("\r\n");
				string line = buffer[0 .. end];
				buffer = buffer[end + 2 .. $];
				return line;
			}

			void reply(string text) { client.send(text ~ "\r\n"); }

			reply("220 fake");

			while (true)
			{
				string line = readLine();
				if (line is null) return;

				record(line);
				string command = line.toUpper;

				if (command.startsWith("EHLO")) reply("250-fake\r\n250 AUTH PLAIN LOGIN XOAUTH2");
				else if (command == "AUTH XOAUTH2" || command == "AUTH PLAIN") { reply("334 "); record(readLine()); reply("235 ok"); }
				else if (command.startsWith("AUTH")) reply("235 ok");
				else if (command == "DATA") {
					reply("354 go");
					while (true) { string data = readLine(); if (data is null || data == ".") break; }
					reply("250 queued");
				}
				else if (command == "QUIT") { reply("221 bye"); return; }
				else reply("250 ok");
			}
		}
	}
}

// send() puts To, Cc and Bcc in the envelope, and the sender in MAIL FROM
unittest
{
	auto server = new FakeSmtpServer();
	scope(exit) server.stop();

	new Email()
		.setFrom("sender@example.com")
		.addTo("to@example.com")
		.addCc("cc@example.com")
		.addBcc("bcc@example.com")
		.setPlainTextBody("Hi")
		.send("smtp://localhost:" ~ server.port.to!string);

	auto commands = server.commands();
	assert(commands.canFind("MAIL FROM:<sender@example.com>"));
	assert(commands.canFind("RCPT TO:<to@example.com>"));
	assert(commands.canFind("RCPT TO:<cc@example.com>"));
	assert(commands.canFind("RCPT TO:<bcc@example.com>"));
}

// send() with OAuth2 authenticates with XOAUTH2: "user=...^Aauth=Bearer ...^A^A" in base64
unittest
{
	auto server = new FakeSmtpServer();
	scope(exit) server.stop();

	auto email = new Email().setFrom("user@example.com").addTo("to@example.com").setPlainTextBody("Hi");

	assertThrown!PostinoException(email.send("smtp://localhost:" ~ server.port.to!string, "", OAuth2("token")));
	assertThrown!PostinoException(email.send("smtp://localhost:" ~ server.port.to!string, "user@example.com", OAuth2("")));

	email.send("smtp://localhost:" ~ server.port.to!string, "user@example.com", OAuth2("ya29.token"));

	// A plain string is still a password: PLAIN, not XOAUTH2
	email.send("smtp://localhost:" ~ server.port.to!string, "user@example.com", "password");
	assert(server.commands().filter!(c => c == "AUTH XOAUTH2").count == 1);
	assert(server.commands().canFind("AUTH PLAIN"));

	auto commands = server.commands();
	auto auth = commands.countUntil("AUTH XOAUTH2");
	assert(auth >= 0, commands.join(" | "));
	assert(cast(string)Base64.decode(commands[auth + 1]) == "user=user@example.com\x01auth=Bearer ya29.token\x01\x01");
	assert(commands.canFind("RCPT TO:<to@example.com>"));
}

// The same SMTP object reuses the connection: one connection for many emails
unittest
{
	auto server = new FakeSmtpServer();
	scope(exit) server.stop();

	auto newsletter = new Email()
		.setFrom("news@example.com")
		.setSubject("News")
		.setPlainTextBody("Hi");

	auto smtp = SMTP();

	foreach (address; ["one@example.com", "two@example.com", "three@example.com"])
		newsletter.clone().addTo(address).send("smtp://localhost:" ~ server.port.to!string, "user", "password", smtp);

	import core.atomic : atomicLoad;
	assert(atomicLoad(server.connections) == 1, atomicLoad(server.connections).to!string);

	// Each email went to its own recipient only
	auto rcpt = server.commands().filter!(c => c.startsWith("RCPT TO:")).array;
	assert(rcpt == ["RCPT TO:<one@example.com>", "RCPT TO:<two@example.com>", "RCPT TO:<three@example.com>"], rcpt.join(" | "));
	assert(newsletter.to.length == 0);
}

// One SMTP object, different credentials: each send uses its own, never those of the previous one
unittest
{
	import core.atomic : atomicLoad;

	auto server = new FakeSmtpServer();
	scope(exit) server.stop();

	immutable url = "smtp://localhost:" ~ server.port.to!string;
	auto smtp = SMTP();
	auto mail(string to) { return new Email().setFrom("a@example.com").addTo(to).setPlainTextBody("Hi"); }

	// The credentials sent after each AUTH, decoded
	string[] logins()
	{
		string[] result;
		auto commands = server.commands();

		foreach (i, c; commands)
			if (c.startsWith("AUTH") && i + 1 < commands.length)
				result ~= cast(string)Base64.decode(commands[i + 1]);

		return result;
	}

	mail("1@example.com").send(url, "mario", "pw1", smtp);
	mail("2@example.com").send(url, "mario", "pw1", smtp);           // same credentials: same connection
	assert(atomicLoad(server.connections) == 1);

	mail("3@example.com").send(url, "mario", "pw2", smtp);           // new password: new login
	mail("4@example.com").send(url, "luigi", OAuth2("tok"), smtp);   // OAuth2 after a password
	mail("5@example.com").send(url, "luigi", "pw3", smtp);           // a password after OAuth2: no token left
	mail("6@example.com").send(url, "", "", smtp);                   // no credentials: no login at all

	assert(logins() == ["\0mario\0pw1", "\0mario\0pw2", "user=luigi\x01auth=Bearer tok\x01\x01", "\0luigi\0pw3"], logins().join(" | "));

	// The last email did not reuse the authenticated connection
	assert(atomicLoad(server.connections) == 5, atomicLoad(server.connections).to!string);
	assert(server.commands().canFind("RCPT TO:<6@example.com>"));
}

// A new SMTP object for each email opens a new connection
unittest
{
	auto server = new FakeSmtpServer();
	scope(exit) server.stop();

	foreach (i; 0 .. 2)
		new Email().setFrom("a@example.com").addTo("b@example.com").setPlainTextBody("Hi")
			.send("smtp://localhost:" ~ server.port.to!string);

	import core.atomic : atomicLoad;
	assert(atomicLoad(server.connections) == 2);
}

// Custom headers
unittest
{
	auto email = new Email()
		.setFrom("sender@example.com")
		.addTo("to@example.com")
		.setSubject("Hi")
		.addHeader("List-Unsubscribe", "<https://example.com/u?id=1>, <mailto:u@example.com>")
		.addHeader("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")
		.addHeader("X-Note", "perché sì")
		.addHeader("References", "<a@example.com>")
		.addHeader("References", "<b@example.com>");

	string headers = headersOf(email.build());
	assert(headers.canFind("\r\nSubject: Hi\r\nList-Unsubscribe: <https://example.com/u?id=1>, <mailto:u@example.com>\r\n"
		~ "List-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n"));
	assert(headers.canFind("\r\nX-Note: =?UTF-8?B?" ~ Base64.encode(cast(ubyte[])"perché sì") ~ "?=\r\n"));
	assert(headers.canFind("\r\nReferences: <a@example.com>\r\nReferences: <b@example.com>\r\n"));

	// Reserved, invalid names and values
	foreach (name; ["From", "to", "BCC", "Subject", "Date", "Message-ID", "MIME-Version", "Reply-To", "Content-Type", "content-transfer-encoding"])
		assertThrown!PostinoException(email.addHeader(name, "x"), name);

	foreach (name; ["", "X Note", "X:Note", "X-Nötè", "X\r\nBcc"])
		assertThrown!PostinoException(email.addHeader(name, "x"), name);

	assertThrown!PostinoException(email.addHeader("X-Evil", "a\r\nBcc: victim@example.com"));
	assertThrown!PostinoException(email.addHeader("X-Evil", "a\nb"));
	assertThrown!PostinoException(email.addHeader("X-Long", "a".replicate(1000)));

	string message = email.clearHeaders().build();
	assert(!message.canFind("List-Unsubscribe") && !message.canFind("X-Note"));
}

// clone() copies everything, the copy and the original are independent
unittest
{
	auto original = new Email()
		.setFrom("sender@example.com", "Sender")
		.addTo("to@example.com")
		.addCc("cc@example.com")
		.addBcc("bcc@example.com")
		.setReplyTo("reply@example.com")
		.setSubject("Subject")
		.setPlainTextBody("Text")
		.setHtmlBody("<p>Html</p>")
		.addHeader("X-Test", "1")
		.addEmbeddedFile(cast(ubyte[])"png", "logo", "image/png")
		.addAttachment(cast(ubyte[])"pdf", "application/pdf", "doc.pdf");

	auto copy = original.clone();
	assert(copy !is original);

	string a = original.build(), b = copy.build();
	foreach (piece; ["From: Sender <sender@example.com>", "To: to@example.com", "Cc: cc@example.com", "Reply-To: reply@example.com",
		"Subject: Subject", "X-Test: 1", "Content-ID: <logo>", "filename=\"doc.pdf\""])
		assert(a.canFind(piece) && b.canFind(piece), piece);
	assert(copy.envelopeRecipients() == original.envelopeRecipients());

	copy.clearTo().clearCc().clearBcc().addTo("other@example.com").clearHeaders().clearEmbeddedFiles().clearAttachments();

	assert(original.envelopeRecipients().length == 3);
	assert(original.headers.length == 1 && original.embeddedFiles.length == 1 && original.attachments.length == 1);
	assert(copy.envelopeRecipients().map!(r => r.address).array == ["other@example.com"]);

	string c = copy.build();
	assert(!c.canFind("X-Test") && !c.canFind("Content-ID") && !c.canFind("doc.pdf")
		&& !c.canFind("multipart/mixed") && !c.canFind("multipart/related") && c.canFind("multipart/alternative"));
}

// Internationalized domains become punycode, non-ASCII before @ is refused
unittest
{
	assert(Email.punycode("bücher"d) == "bcher-kva");
	assert(Email.punycode("città"d) == "citt-3na");
	assert(Email.punycode("日本"d) == "wgv71a");
	assert(Email.punycode("münchen"d) == "mnchen-3ya");
	assert(Email.punycode("straße"d) == "strae-oqa");

	assert(Email.validateEmailAddress("info@città.it") == "info@xn--citt-3na.it");
	assert(Email.validateEmailAddress("info@CITTÀ.it") == "info@xn--citt-3na.it");
	assert(Email.validateEmailAddress("a@mail.bücher.de") == "a@mail.xn--bcher-kva.de");
	assert(Email.validateEmailAddress("a@日本.jp") == "a@xn--wgv71a.jp");
	assert(Email.validateEmailAddress("a@example.com") == "a@example.com");

	// NFD (e + combining grave) and NFC give the same domain
	assert(Email.validateEmailAddress("a@città.it") == "a@xn--citt-3na.it");

	assertThrown!PostinoException(new Email().addTo("andrè@example.com"));

	string message = new Email()
		.setFrom("info@città.it", "Città")
		.addTo("ufficio@bücher.de")
		.setPlainTextBody("Hi")
		.build();

	assert(headersOf(message).canFind("\r\nTo: ufficio@xn--bcher-kva.de\r\n"));
	assert(headersOf(message).canFind(" <info@xn--citt-3na.it>\r\n"));
	assert(headersOf(message).canFind("@xn--citt-3na.it>\r\n"));    // Message-ID
}

// Every error of postino is a PostinoException
unittest
{
	assertThrown!PostinoException(new Email().addTo("not an address"));
	assertThrown!PostinoException(new Email().addEmbeddedFile(cast(ubyte[])"x", "<id>", "image/png"));
	assertThrown!PostinoException(new Email().addAttachment(cast(ubyte[])"x", "png"));
	assertThrown!PostinoException(new Email().addTo("a@example.com").build());
	assertThrown!PostinoException(new Email().setFrom("a@example.com").addTo("b@example.com").attachFile("/nonexistent/file").build());
}

// The old names with a path still work, as deprecated aliases of attachFile and embedFile
deprecated unittest
{
	string path = tempFile("old.txt");
	write(path, "old api");
	scope(exit) remove(path);

	string message = new Email()
		.setFrom("a@example.com")
		.addTo("b@example.com")
		.setHtmlBody("<img src='cid:x'>")
		.addEmbeddedFile(path, "x", "image/png")
		.addAttachment(path)
		.build();

	assert(message.canFind("Content-ID: <x>"));
	assert(message.canFind("filename=\"" ~ baseName(path) ~ "\""));
	assert(message.canFind(Base64.encode(cast(ubyte[])"old api")));
}

// Audit 1: credentials in the URL are refused, never sent
unittest
{
	auto server = new FakeSmtpServer();
	scope(exit) server.stop();

	auto email = new Email().setFrom("a@example.com").addTo("b@example.com").setPlainTextBody("Hi");
	immutable port = server.port.to!string;

	foreach (url; ["smtp://user:secret@0.0.0.0:" ~ port, "smtp://user@localhost:" ~ port, "smtps://user:secret@smtp.example.com"])
		assert(collectExceptionMsg!PostinoException(email.send(url)).canFind("credentials"), url);

	assert(atomicLoad(server.connections) == 0);
}

// Audit 2: the host checked is the host libcurl connects to; only real loopback addresses are local
unittest
{
	auto server = new FakeSmtpServer("0.0.0.0");
	scope(exit) server.stop();

	auto email = new Email().setFrom("a@example.com").addTo("b@example.com").setPlainTextBody("Hi");
	immutable remote = "smtp://" ~ remoteTestHost() ~ ":" ~ server.port.to!string;

	// "?@localhost" and "#@localhost" used to make the host look local
	foreach (url; [remote ~ "?@localhost", remote ~ "#@localhost", remote ~ "/?x"])
		assertThrown!PostinoException(email.send(url, "user", "secret"), url);

	assert(atomicLoad(server.connections) == 0);

	// A remote server: STARTTLS is required, the fake server does not offer it.
	// The connection is made (EHLO), but the credentials are never sent
	assertThrown(email.send(remote, "user", "secret"));
	assert(atomicLoad(server.connections) == 1);
	assert(server.commands().any!(c => c.startsWith("EHLO")));
	assert(!server.commands().any!(c => c.startsWith("AUTH")));

	foreach (host; ["localhost", "127.0.0.1", "127.1.2.3", "::1"])
		assert(Email.isLoopback(host), host);

	foreach (host; ["127.evil.com", "127.0.0.1.nip.io", "localhost.evil.com", "0.0.0.0", "10.0.0.1", "::ffff:127.0.0.1", "2001:db8::1", "example.com"])
		assert(!Email.isLoopback(host), host);

	assert(Email.requiresStartTls("smtp://127.evil.com:587"));

	foreach (url; ["http://example.com", "smtp://", "smtp://:25", "smtp://[::1", "smtp://exa mple.com", "smtp://example.com\r\n"])
		assertThrown!PostinoException(Email.smtpHost(url), url);
}

// Audit 3: data from memory is copied, clone() can't share it with the caller
unittest
{
	ubyte[] buffer = "alice-data".dup.representation;

	auto alice = new Email().setFrom("a@example.com").addTo("alice@example.com")
		.addAttachment(buffer, "text/plain", "data.txt")
		.addEmbeddedFile(buffer, "img", "image/png");

	auto copy = alice.clone();

	buffer[0 .. 5] = "bobby".representation;   // the caller reuses its buffer for the next recipient

	foreach (message; [alice.build(), copy.build()])
	{
		assert(message.canFind(Base64.encode("alice-data".representation)));
		assert(!message.canFind(Base64.encode("bobby-data".representation)));
	}
}

// Audit 4: attachFile and embedFile read files, addAttachment and addEmbeddedFile take data only
unittest
{
	auto email = new Email().setFrom("a@example.com").addTo("b@example.com");

	assertThrown!PostinoException(email.attachFile(""));
	assertThrown!PostinoException(email.embedFile("", "x"));

	// A directory or a missing file is a PostinoException at build time
	assertThrown!PostinoException(email.clone().attachFile(tempDir).build());
	assertThrown!PostinoException(email.clone().embedFile("/nonexistent/x.png", "x").build());

	// Text as data: the content is sent, no file is read
	string csv = "/etc/passwd";
	string message = email.clone().addAttachment(csv.representation, "text/csv", "a.csv").build();
	assert(message.canFind(Base64.encode("/etc/passwd".representation)));
}

// Audit 5: only CR and LF end a line, other separators are content
unittest
{
	assert(Email.encodeQuotedPrintable("a\u2028b") == "a=E2=80=A8b\r\n");
	assert(Email.encodeQuotedPrintable("a\u2029b\u0085c") == "a=E2=80=A9b=C2=85c\r\n");
	assert(Email.encodeQuotedPrintable("a\fb\vc") == "a=0Cb=0Bc\r\n");
	assert(Email.encodeQuotedPrintable("a\r\nb\nc\rd\n") == "a\r\nb\r\nc\r\nd\r\n");
	assert(Email.encodeQuotedPrintable("a\n\n") == "a\r\n\r\n");
	assert(Email.encodeQuotedPrintable("") == "");
}

// Audit 6: domains are mapped as browsers do, invisible characters are refused
unittest
{
	// Fullwidth letters and ideographic dots become plain ASCII
	assert(Email.validateEmailAddress("a@ｅｘａｍｐｌｅ.com") == "a@example.com");
	assert(Email.validateEmailAddress("a@example。com") == "a@example.com");
	assert(Email.validateEmailAddress("a@example．com") == "a@example.com");
	assert(Email.validateEmailAddress("a@città｡it") == "a@xn--citt-3na.it");

	// Invisible characters and symbols
	foreach (bad; ["a@exam\u00ADple.com", "a@exam\u200Bple.com", "a@exa\u200Dmple.com", "a@ex★ample.com", "a@exam＠ple.com", "a@exam（ple.com"])
		assertThrown!PostinoException(Email.validateEmailAddress(bad), bad);

	// Invalid UTF-8
	assertThrown!PostinoException(Email.validateEmailAddress("a@exam\xFFple.com"));

	// The length is checked after the conversion
	string longLabel = "è".replicate(30);
	assertThrown!PostinoException(Email.validateEmailAddress("a@" ~ [longLabel, longLabel, longLabel, longLabel, longLabel].join(".") ~ ".it"));
}

// Audit 7: names and subjects that look like encoded-words are shown as they are, not decoded
unittest
{
	string headers = headersOf(new Email()
		.setFrom("a@example.com", "=?UTF-8?B?c3VwcG9ydEBiYW5rLmNvbQ==?=")
		.addTo("b@example.com")
		.setSubject("=?UTF-8?B?ZmFrZQ==?=")
		.addHeader("X-Note", "=?UTF-8?B?ZmFrZQ==?=")
		.build());

	assert(headers.canFind("\r\nFrom: \"=?UTF-8?B?c3VwcG9ydEBiYW5rLmNvbQ==?=\" <a@example.com>\r\n"));
	assert(headers.canFind("\r\nSubject: =?UTF-8?B?" ~ Base64.encode("=?UTF-8?B?ZmFrZQ==?=".representation) ~ "?="));
	assert(headers.canFind("\r\nX-Note: =?UTF-8?B?" ~ Base64.encode("=?UTF-8?B?ZmFrZQ==?=".representation) ~ "?="));
}

// Audit 8: control characters never reach the headers, invalid UTF-8 is refused
unittest
{
	string headers = headersOf(new Email()
		.setFrom("a@example.com", "Na\x1Bme\x7F")
		.addTo("b@example.com")
		.setSubject("Sub\x0Bject\x1B[31m\tok")
		.addAttachment("x".representation, "text/plain", "fi\x1Ble.txt")
		.build());

	foreach (char c; headers)
		assert(c >= 32 && c != 127 || c == '\r' || c == '\n' || c == '\t', format("%02X", cast(ubyte)c));

	assert(headers.canFind("\r\nSubject: Subject[31m\tok\r\n"));

	auto email = new Email();
	assertThrown!PostinoException(email.addHeader("X-A", "a\x0Bb"));
	assertThrown!PostinoException(email.addHeader("X-A", "a\x1Bb"));
	assertThrown!PostinoException(email.addHeader("X-A", "a\x7Fb"));
	assertNotThrown(email.addHeader("X-A", "a\tb"));

	assertThrown!PostinoException(email.setSubject("bad \xFF utf-8"));
	assertThrown!PostinoException(email.setPlainTextBody("bad \xC3"));
	assertThrown!PostinoException(email.setHtmlBody("\xFE"));
	assertThrown!PostinoException(email.addTo("b@example.com", "bad \xFF"));
	assertThrown!PostinoException(email.addHeader("X-A", "\xFF"));
	assertThrown!PostinoException(email.addAttachment("x".representation, "text/plain", "bad\xFF.txt"));
}

// Audit 9: use_ssl is set at every send, a reused SMTP object does not keep it
unittest
{
	auto server = new FakeSmtpServer("0.0.0.0");
	scope(exit) server.stop();

	immutable port = server.port.to!string;
	auto mail() { return new Email().setFrom("a@example.com").addTo("b@example.com").setPlainTextBody("Hi"); }
	auto smtp = SMTP();

	// A remote server with credentials: STARTTLS required, refused by the fake server
	assertThrown(mail().send("smtp://" ~ remoteTestHost() ~ ":" ~ port, "user", "secret", smtp));
	assert(server.commands().any!(c => c.startsWith("EHLO")) && !server.commands().any!(c => c.startsWith("AUTH")));

	// Then a local one without credentials, with the same SMTP object: plain SMTP works
	mail().send("smtp://localhost:" ~ port, "", "", smtp);
	assert(server.commands().canFind("RCPT TO:<b@example.com>"));
}

// Audit 10: filename* is a valid RFC 2231 value
unittest
{
	assert(Email.percentEncode("l'été (1)*.txt") == "l%27%C3%A9t%C3%A9%20%281%29%2A.txt");
	assert(Email.percentEncode("a-b_c.d~e!#$&+^`|") == "a-b_c.d~e!#$&+^`|");

	string message = new Email().setFrom("a@example.com").addTo("b@example.com")
		.addAttachment("x".representation, "text/plain", "l'été (1).txt").build();

	assert(message.canFind("filename*=UTF-8''l%27%C3%A9t%C3%A9%20%281%29.txt;"));
}

// Audit 11: a long ASCII subject is folded at spaces, every header line stays short
unittest
{
	string subject = "word ".replicate(300).strip;
	string headers = headersOf(new Email().setFrom("a@example.com").addTo("b@example.com").setSubject(subject).build());

	foreach (line; headers.split("\r\n"))
		assert(line.length <= 78, line);

	// Unfolding gives the subject back
	auto start = headers.indexOf("\r\nSubject: ") + "\r\nSubject: ".length;
	auto end = headers.indexOf("\r\n", start);
	while (headers[end + 2] == ' ') end = headers.indexOf("\r\n", end + 2);
	assert(headers[start .. end].replace("\r\n", "") == subject);

	// A single word too long for a line is encoded
	string longWord = "x".replicate(1200);
	headers = headersOf(new Email().setFrom("a@example.com").addTo("b@example.com").setSubject(longWord).build());

	foreach (line; headers.split("\r\n"))
		assert(line.length <= 78, line[0 .. 20]);
}

// Audit 13: a boundary never appears in the content it separates
unittest
{
	string[] parts = ["text with postino_alt_ inside", "more"];

	foreach (i; 0 .. 100)
	{
		string boundary = Email.randomBoundary("alt", parts);
		assert(boundary.startsWith("postino_alt_") && boundary.length == "postino_alt_".length + 64);
		assert(!parts.any!(p => p.canFind(boundary)));
	}
}

// Audit 14: MIME types from upper case extensions, .ts is video/mp2t
unittest
{
	auto email = new Email();
	assert(email.getMimeType("photo.JPG") == "image/jpeg");
	assert(email.getMimeType("Report.PDF") == "application/pdf");
	assert(email.getMimeType("clip.ts") == "video/mp2t");
	assert(email.getMimeType("noext") == "application/octet-stream");
}
