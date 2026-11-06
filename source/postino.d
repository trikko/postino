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
import std.array : array, join;
import std.algorithm.searching : canFind;
import std.string : replace, toLower;
import std.conv : to;
import std.file : exists, read;
import std.path : baseName, extension;
import std.base64 : Base64;
import std.datetime : Clock, SysTime;
import std.random : uniform;
import std.digest.sha : sha384Of;
import std.range : chunks;
import std.net.curl : SMTP;
import std.utf : toUTF8, stride;
import std.format : format;
import std.algorithm.searching : startsWith, endsWith, count;
import etc.c.curl : CurlOption, CurlUseSSL;

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
	 * Throws: Exception if the address is not a valid email address
	 *
	 * Example:
	 * ---
	 * email.setFrom("sender@example.com", "John Doe")
	 *      .addTo("recipient@example.com");
	 * ---
	 */
	auto setFrom(string address, string name = string.init)
	{
		this.from = Recipient(validateEmailAddress(address), name);
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
	 * Throws: Exception if the address is not a valid email address
	 *
	 * Example:
	 * ---
	 * email.addTo("recipient1@example.com", "Jane Smith")
	 *      .addTo("recipient2@example.com");
	 * ---
	 */
	auto addTo(string address, string name = string.init)
	{
		this.to ~= Recipient(validateEmailAddress(address), name);
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
		this.subject = subject;
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
	 * Throws: Exception if the address is not a valid email address
	 *
	 * Example:
	 * ---
	 * email.addCc("manager@example.com", "Project Manager")
	 *      .addCc("team@example.com");
	 * ---
	 */
	auto addCc(string address, string name = string.init)
	{
		this.cc ~= Recipient(validateEmailAddress(address), name);
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
	 * Throws: Exception if the address is not a valid email address
	 *
	 * Example:
	 * ---
	 * email.addBcc("archive@example.com", "Email Archive")
	 *      .addBcc("backup@example.com");
	 * ---
	 */
	auto addBcc(string address, string name = string.init)
	{
		this.bcc ~= Recipient(validateEmailAddress(address), name);
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
	 * Throws: Exception if the address is not a valid email address
	 *
	 * Example:
	 * ---
	 * email.setReplyTo("noreply@example.com", "No Reply")
	 *      .setSubject("Newsletter");
	 * ---
	 */
	auto setReplyTo(string address, string name = string.init)
	{
		this.replyTo = Recipient(validateEmailAddress(address), name);
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
		this.plainTextBody = body;
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
		this.htmlBody = body;
		return this;
	}

	/**
	 * Adds an embedded file (inline attachment) to the email.
	 * Embedded files can be referenced in HTML content using their Content-ID.
	 *
	 * Params:
	 *     path = Path to the file to embed
	 *     cid = Content-ID for referencing in HTML (e.g., "image1" for src="cid:image1")
	 *     mimeType = Optional MIME type override (auto-detected if not provided)
	 *
	 * Returns: Reference to this Email object for method chaining
	 *
	 * Throws: Exception if cid or mimeType are not valid. A missing file is reported by send() and save()
	 *
	 * Example:
	 * ---
	 * email.addEmbeddedFile("/path/to/logo.png", "logo")
	 *      .setHtmlBody("<img src='cid:logo'>");
	 * ---
	 */
	auto addEmbeddedFile(string path, string cid, string mimeType = string.init)
	{
		if (mimeType.length == 0)
			mimeType = getMimeType(path);

		this.embeddedFiles[validateContentId(cid)] = Attachment(baseName(path), path, [], validateMimeType(mimeType));
		return this;
	}

	/// DITTO
	auto addEmbeddedFile(ubyte[] data, string cid, string mimeType)
	{
		if (mimeType.length == 0)
			mimeType = "application/octet-stream";

		this.embeddedFiles[validateContentId(cid)] = Attachment(string.init, string.init, data, validateMimeType(mimeType));
		return this;
	}

	/**
	 * Adds a file attachment to the email.
	 * Attachments appear as downloadable files in the email client.
	 *
	 * Params:
	 *     path = Path to the file to attach
	 *     mimeType = Optional MIME type override (auto-detected if not provided)
	 *     name = Optional file name shown to the recipient (the base name of path if not provided)
	 *
	 * Returns: Reference to this Email object for method chaining
	 *
	 * Throws: Exception if mimeType is not valid. A missing file is reported by send() and save()
	 *
	 * Example:
	 * ---
	 * email.addAttachment("/path/to/document.pdf")
	 *      .addAttachment("/path/to/report.xlsx");
	 * ---
	 */
	auto addAttachment(string path, string mimeType = string.init, string name = string.init)
	{
		if (name.length == 0)
			name = baseName(path);

		if (mimeType.length == 0)
			mimeType = getMimeType(path);

		this.attachments ~= Attachment(name, path, [], validateMimeType(mimeType));
		return this;
	}

   /// DITTO
	auto addAttachment(ubyte[] data, string mimeType, string name = string.init)
	{
		import std.uuid : randomUUID;

		if (name.length == 0)
			name = randomUUID().toString();

		if (mimeType.length == 0)
			mimeType = getMimeType(name);

		this.attachments ~= Attachment(name, string.init, data, validateMimeType(mimeType));
		return this;
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
	 * Params:
	 *     smtpServerUrl = SMTP server URL (e.g., "smtps://smtp.gmail.com:465" or "smtp://smtp.example.com:587")
	 *     username = SMTP authentication username (optional)
	 *     password = SMTP authentication password (optional)
	 *     smtp = Pre-configured SMTP object (optional)
	 *
	 * Returns: true if the email was sent successfully
	 *
	 * Throws: Exception if the email has no sender or no recipients, if a file to attach is missing,
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

		smtp.url = smtpServerUrl;

		// Never send credentials in clear: plain smtp:// must upgrade the connection with STARTTLS
		if (hasCredentials && requiresStartTls(smtpServerUrl))
			smtp.handle.set(CurlOption.use_ssl, CurlUseSSL.all);

		if (hasCredentials)
			smtp.setAuthentication(username, password);

		// Build first: it checks sender, recipients and files before anything is sent
		smtp.message = build();

		// Envelope recipients: To, Cc and Bcc. Bcc is not written in the headers.
		smtp.mailTo = envelopeRecipients().map!(r => formatEmailOnly(r).to!(const(char)[])).array;
		smtp.mailFrom = formatEmailOnly(from);

		smtp.perform();
		return true;
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
	 * Throws: Exception if the email has no sender or no recipients, if a file to attach is missing,
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

	struct Attachment
	{
		string name;
		string path;
		ubyte[] data;
		string mimeType;
	}

	struct Recipient
	{
		string address;
		string name;
	}

	shared static this() { startTime = Clock.currTime; }

	string randomBoundary(string prefix)
	{
		import std.digest.sha;
		string result = "";

		foreach(i; 0..64) result ~= "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"[uniform(0, 62)];

		return "mail_sender_" ~ prefix ~ "_" ~ result ~ "_" ~ sha384Of((Clock.currTime - startTime).total!"usecs".to!string).toHexString.toLower[32..64];
	}

	string build()
	{
		if (from.address.length == 0)
			throw new Exception("Missing sender: call setFrom()");

		if (to.length + cc.length + bcc.length == 0)
			throw new Exception("Missing recipients: call addTo(), addCc() or addBcc()");

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

		result ~= "Subject: " ~ encodeHeaderText(subject) ~ "\r\n";

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
		string boundary = randomBoundary(subtype);
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

		// Check if it contains special characters that require quotes
		bool needsQuotes = false;
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

	// Check an email address (addr-spec, without display name) and return it.
	// CR, LF and every other control character are rejected, not removed: a header can't be injected.
	static string validateEmailAddress(string email)
	{
		import std.string : indexOf, split;

		void fail(string reason) { throw new Exception("Invalid email address `" ~ sanitizeHeader(email) ~ "`: " ~ reason); }

		if (email.length == 0) fail("empty");
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

		if (domain.length == 0) fail("missing domain");

		foreach (label; domain.split(".")) {
			if (label.length == 0) fail("empty label in domain");
			if (label.startsWith("-") || label.endsWith("-")) fail("domain label starts or ends with -");
		}

		return email;
	}

	// Content-ID of an embedded file: printable ASCII, no spaces and no <>
	static string validateContentId(string cid)
	{
		if (cid.length == 0)
			throw new Exception("Invalid Content-ID: empty");

		foreach (char c; cid)
			if (c < 33 || c > 126 || "<>()[]\\,;:\"".canFind(c))
				throw new Exception("Invalid Content-ID `" ~ sanitizeHeader(cid) ~ "`: use letters, digits and .-_@");

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
			throw new Exception("Invalid MIME type `" ~ sanitizeHeader(mimeType) ~ "`: expected type/subtype, e.g. image/png");

		return mimeType;
	}

	ubyte[] readAttachmentData(ref Attachment attachment)
	{
		// Data given directly
		if (attachment.path.length == 0)
			return attachment.data;

		// Read from file
		if (!exists(attachment.path))
			throw new Exception("File not found: " ~ attachment.path);

		return cast(ubyte[])read(attachment.path);
	}

	string encodeBase64Lines(ubyte[] data)
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
		import std.uri : encodeComponent;

		string sanitized = sanitizeHeader(fileName);
		string ascii = "";

		foreach (dchar c; sanitized)
			ascii ~= (c > 126 || c < 32) ? '_' : cast(char)c;

		// Escape backslash first, then quotes: the other way round doubles the escapes
		string result = "\r\n filename=\"" ~ ascii.replace("\\", "\\\\").replace("\"", "\\\"") ~ "\"";

		// filename* first: parsers that read only one of the two take the first
		if (hasNonAscii(sanitized))
			result = "\r\n filename*=UTF-8''" ~ encodeComponent(sanitized) ~ ";" ~ result;

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
			".ts" : "application/typescript",
			".atom" : "application/atom+xml", ".rss" : "application/rss+xml",
			".mml" : "text/mathml"
		];

		if (filePath.extension in mimes)
			return mimes[filePath.extension];

		return "application/octet-stream";
	}

	static string sanitizeHeader(string input)
	{
		// Remove or replace dangerous characters
		return input.replace("\r", "").replace("\n", "").replace("\0", "");
	}

	static bool hasNonAscii(string s)
	{
		foreach (char c; s)
			if (c > 127)
				return true;

		return false;
	}

	// Text for a header (the subject): RFC 2047 if it contains non-ASCII characters
	string encodeHeaderText(string text)
	{
		string sanitized = sanitizeHeader(text);

		if (hasNonAscii(sanitized))
			return encodeWords(sanitized);

		return sanitized;
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
		import std.string : lineSplitter;

		string result = "";

		foreach (line; text.lineSplitter)
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

	// With smtp:// and credentials STARTTLS is required, unless the server is on this machine
	static bool requiresStartTls(string smtpServerUrl)
	{
		import std.string : indexOf;

		string url = smtpServerUrl.toLower;

		if (!url.startsWith("smtp://"))
			return false; // smtps:// is already TLS

		string host = url["smtp://".length .. $];

		auto slash = host.indexOf('/');
		if (slash >= 0) host = host[0 .. slash];

		auto at = host.indexOf('@');
		if (at >= 0) host = host[at + 1 .. $];

		if (host.startsWith("[")) {
			auto close = host.indexOf(']');
			host = close >= 0 ? host[1 .. close] : host[1 .. $];
		} else {
			auto colon = host.indexOf(':');
			if (colon >= 0) host = host[0 .. colon];
		}

		immutable isLocal = host == "localhost" || host.startsWith("127.") || host == "::1";
		return !isLocal;
	}

	Attachment[string] embeddedFiles;
	Attachment[] attachments;

	Recipient from;
	Recipient[] to;
	string subject;
	Recipient[] cc;
	Recipient[] bcc;
	Recipient replyTo;

	string plainTextBody;
	string htmlBody;

	__gshared SysTime startTime;
}

version(unittest)
{
	import std.file : tempDir, remove, readText, write;
	import std.array : split;
	import std.path : buildPath;
	import std.string : indexOf, splitLines;
	import std.exception : assertThrown, assertNotThrown;

	// Headers of a message: everything before the first empty line
	string headersOf(string message)
	{
		return message[0 .. message.indexOf("\r\n\r\n") + 2];
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
	assertThrown(email.addAttachment("file.txt", "text/plain; charset=utf-8"));

	string path = tempFile("data.bin");
	write(path, "data");
	scope(exit) remove(path);

	string message = email
		.setFrom("sender@example.com")
		.addTo("to@example.com")
		.setHtmlBody("<img src='cid:logo'>")
		.addEmbeddedFile(path, "logo", "image/png")
		.addAttachment(path, "application/x-custom", "custom.bin")
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
		.addAttachment("/nonexistent/postino/report.pdf");

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
