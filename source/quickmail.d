module quickmail;

import std.algorithm : map;
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
import std.utf : toUTF8;

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
	 * Example:
	 * ---
	 * email.setFrom("sender@example.com", "John Doe")
	 *      .addTo("recipient@example.com");
	 * ---
	 */
	auto setFrom(string address, string name = string.init)
	{
		this.from = Recipient(address, name);
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
	 * Example:
	 * ---
	 * email.addTo("recipient1@example.com", "Jane Smith")
	 *      .addTo("recipient2@example.com");
	 * ---
	 */
	auto addTo(string address, string name = string.init)
	{
		this.to ~= Recipient(address, name);
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
	 *
	 * Params:
	 *     address = The Cc recipient's email address
	 *     name = Optional display name for the recipient
	 *
	 * Returns: Reference to this Email object for method chaining
	 *
	 * Example:
	 * ---
	 * email.addCc("manager@example.com", "Project Manager")
	 *      .addCc("team@example.com");
	 * ---
	 */
	auto addCc(string address, string name = string.init)
	{
		this.cc ~= Recipient(address, name);
		return this;
	}

	/**
	 * Adds a recipient to the email's "Bcc" (Blind Carbon Copy) field.
	 * Multiple Bcc recipients can be added by calling this method multiple times.
	 *
	 * Params:
	 *     address = The Bcc recipient's email address
	 *     name = Optional display name for the recipient
	 *
	 * Returns: Reference to this Email object for method chaining
	 *
	 * Example:
	 * ---
	 * email.addBcc("archive@example.com", "Email Archive")
	 *      .addBcc("backup@example.com");
	 * ---
	 */
	auto addBcc(string address, string name = string.init)
	{
		this.bcc ~= Recipient(address, name);
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
	 * Example:
	 * ---
	 * email.setReplyTo("noreply@example.com", "No Reply")
	 *      .setSubject("Newsletter");
	 * ---
	 */
	auto setReplyTo(string address, string name = string.init)
	{
		this.replyTo = Recipient(address, name);
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
	 * Example:
	 * ---
	 * email.addEmbeddedFile("/path/to/logo.png", "logo")
	 *      .setHtmlBody("<img src='cid:logo'>");
	 * ---
	 */
	auto addEmbeddedFile(string path, string cid = string.init, string mimeType = string.init)
	{
		this.embeddedFiles[cid] = path;
		return this;
	}

	/**
	 * Adds a file attachment to the email.
	 * Attachments appear as downloadable files in the email client.
	 *
	 * Params:
	 *     path = Path to the file to attach
	 *     mimeType = Optional MIME type override (auto-detected if not provided)
	 *
	 * Returns: Reference to this Email object for method chaining
	 *
	 * Example:
	 * ---
	 * email.addAttachment("/path/to/document.pdf")
	 *      .addAttachment("/path/to/report.xlsx");
	 * ---
	 */
	auto addAttachment(string path, string mimeType = string.init)
	{
		this.attachments ~= path;
		return this;
	}

	/**
	 * Sends the email using the specified SMTP server.
	 *
	 * Params:
	 *     smtpServerUrl = SMTP server URL (e.g., "smtps://smtp.gmail.com:465")
	 *     username = SMTP authentication username (optional)
	 *     password = SMTP authentication password (optional)
	 *     smtp = Pre-configured SMTP object (optional)
	 *
	 * Returns: true if the email was sent successfully
	 *
	 * Throws: Exception if email validation fails or SMTP operation fails
	 *
	 * Example:
	 * ---
	 * email.send("smtps://smtp.gmail.com:465", "user@gmail.com", "app_password");
	 * email.send("smtp://localhost:25"); // No authentication
	 * ---
	 */
	bool send(string smtpServerUrl, string username = string.init, string password = string.init, SMTP smtp = SMTP())
	{
		smtp.url = smtpServerUrl;

		if (username.length > 0 && password.length > 0)
			smtp.setAuthentication(username, password);

		smtp.mailTo = to.map!(r => formatEmailOnly(r).to!(const(char)[])).array;
		smtp.mailFrom = formatEmailOnly(from);
		smtp.message = build();

		smtp.perform();
		return true;
	}

   private:

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
		// Two random boundaries for the main and alternative parts
		string mainBoundary = randomBoundary("main");
		string altBoundary = randomBoundary("alt");

		// Build the MIME message
		string result = "MIME-Version: 1.0\r\n";
		result ~= "From: " ~ formatRecipient(from) ~ "\r\n";
		result ~= "To: " ~ to.map!(r => formatRecipient(r)).join(", ") ~ "\r\n";
		result ~= "Subject: " ~ encodeSubject(subject) ~ "\r\n";

		if (cc.length > 0)
			result ~= "Cc: " ~ cc.map!(r => formatRecipient(r)).join(", ") ~ "\r\n";

		if (bcc.length > 0)
			result ~= "Bcc: " ~ bcc.map!(r => formatRecipient(r)).join(", ") ~ "\r\n";

		if (replyTo.address.length > 0)
			result ~= "Reply-To: " ~ formatRecipient(replyTo) ~ "\r\n";

		result ~= "Content-Type: multipart/related; boundary=\"" ~ mainBoundary ~ "\"\r\n\r\n";

		// Multipart/alternative section for plain text and HTML
		result ~= "--" ~ mainBoundary ~ "\r\n";
		result ~= "Content-Type: multipart/alternative; boundary=\"" ~ altBoundary ~ "\"\r\n\r\n";

		// Plain text body
		if (plainTextBody.length > 0) {
			result ~= "--" ~ altBoundary ~ "\r\n";
			result ~= "Content-Type: text/plain; charset=\"UTF-8\"\r\n\r\n";
			result ~= plainTextBody ~ "\r\n\r\n";
		}

		// HTML body
		if (htmlBody.length > 0) {
			result ~= "--" ~ altBoundary ~ "\r\n";
			result ~= "Content-Type: text/html; charset=\"UTF-8\"\r\n\r\n";
			result ~= htmlBody ~ "\r\n\r\n";
		}

		// Close the alternative section
		result ~= "--" ~ altBoundary ~ "--\r\n\r\n";

		// Add embedded files (inline images)
		foreach (cid, embeddedFile; embeddedFiles) {
			result ~= "--" ~ mainBoundary ~ "\r\n";
			result ~= buildEmbeddedFile(embeddedFile, cid);
		}

		// Add attachments
		foreach (attachment; attachments) {
			result ~= "--" ~ mainBoundary ~ "\r\n";
			result ~= buildAttachment(attachment);
		}

		// Close the main boundary
		result ~= "--" ~ mainBoundary ~ "--\r\n";

		return result;
	}

	// Format the recipient address and name
	string formatRecipient(Recipient recipient)
	{
		string cleanAddress = sanitizeEmailAddress(recipient.address);

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

		// Check if it contains non-ASCII characters
		bool hasNonAscii = false;
		foreach (char c; sanitized) {
			if (c > 127) {
				hasNonAscii = true;
				break;
			}
		}

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

		if (hasNonAscii) {
			// Encode RFC 2047 for non-ASCII characters
			return "=?UTF-8?B?" ~ Base64.encode(cast(ubyte[])sanitized.toUTF8).to!string ~ "?=";
		} else if (needsQuotes) {
			// Escape quotes and backslash, then enclose in quotes
			string escaped = sanitized.replace("\\", "\\\\").replace("\"", "\\\"");
			return "\"" ~ escaped ~ "\"";
		} else {
			return sanitized;
		}
	}

	string sanitizeEmailAddress(string email)
	{
		string sanitized = sanitizeHeader(email);

		// Basic email format validation
		if (!sanitized.canFind("@") || sanitized.canFind("..")) {
			throw new Exception("Invalid email format");
		}

		return sanitized;
	}

	string sanitizeFilename(string filename)
	{
		return sanitizeHeader(filename)
			.replace("\"", "\\\"")  // Escape quotes for Content-Disposition
			.replace("\\", "\\\\"); // Escape backslash
	}

	string buildEmbeddedFile(string filePath, string contentId)
	{
		string result = "";
		string mimeType = getMimeType(filePath);

		result ~= "Content-Type: " ~ mimeType ~ "\r\n";
		result ~= "Content-ID: <" ~ contentId ~ ">\r\n";
		result ~= "Content-Disposition: inline\r\n";
		result ~= "Content-Transfer-Encoding: base64\r\n\r\n";

		// Read the file and encode it in base64
		if (exists(filePath)) {
			ubyte[] fileData = cast(ubyte[])read(filePath);
			string base64Data = Base64.encode(fileData);

			// Divide in lines of 76 characters as per RFC standard
			foreach(line; base64Data.chunks(76))
				result ~= line.to!string ~ "\r\n";
		}

		result ~= "\r\n";
		return result;
	}

	string buildAttachment(string filePath)
	{
		string result = "";
		string mimeType = getMimeType(filePath);
		string fileName = baseName(filePath);

		result ~= "Content-Type: " ~ mimeType ~ "\r\n";
		result ~= "Content-Disposition: attachment; filename=\"" ~ sanitizeFilename(fileName) ~ "\"\r\n";
		result ~= "Content-Transfer-Encoding: base64\r\n\r\n";

		// Read the file and encode it in base64
		if (exists(filePath)) {
			ubyte[] fileData = cast(ubyte[])read(filePath);
			string base64Data = Base64.encode(fileData);

			// Divide in lines of 76 characters as per RFC standard
			foreach(line; base64Data.chunks(76))
				result ~= line.to!string ~ "\r\n";
		}

		result ~= "\r\n";
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

	string sanitizeHeader(string input)
	{
		// Remove or replace dangerous characters
		return input.replace("\r", "").replace("\n", "").replace("\0", "");
	}

	string encodeSubject(string subject)
	{
		string sanitized = sanitizeHeader(subject);

		// If it contains non-ASCII characters, encode RFC 2047
		bool hasNonAscii = false;
		foreach (char c; sanitized) {
			if (c > 127) {
				hasNonAscii = true;
				break;
			}
		}

		if (hasNonAscii)
			return "=?UTF-8?B?" ~ Base64.encode(cast(ubyte[])sanitized.toUTF8).to!string ~ "?=";

		return sanitized;
	}

	string formatEmailOnly(Recipient recipient)
	{
		return "<" ~ sanitizeEmailAddress(recipient.address) ~ ">";
	}

	string[string] embeddedFiles;
	string[] attachments;

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