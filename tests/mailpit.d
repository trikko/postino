/+ dub.sdl:
name "mailpit"
dependency "postino" path=".."
+/
// End-to-end tests: postino sends to Mailpit, the test reads what Mailpit received through its API.
// Start the servers with tests/mailpit.sh, which also builds and runs this file.
//
// Environment (defaults match tests/mailpit.sh):
//   MAILPIT_SMTP=31025 MAILPIT_API=38025          plain SMTP, any credentials accepted
//   MAILPIT_TLS_SMTP=31026 MAILPIT_TLS_API=38026  STARTTLS required, self-signed certificate
//   POSTINO_TEST_HOST                             a non-loopback address of this machine (detected if missing)

import postino;

import std.algorithm : canFind, map, sort;
import std.array : array;
import std.conv : to;
import std.exception : assertThrown;
import std.json : JSONValue, parseJSON;
import std.net.curl : HTTP, SMTP, get, del;
import std.process : environment;
import std.stdio : writeln;
import etc.c.curl : CurlOption;

string apiPlain, apiTls;
string smtpPlain, smtpTls;

void main()
{
	immutable host = environment.get("POSTINO_TEST_HOST", localAddress());

	smtpPlain = environment.get("MAILPIT_SMTP", "31025");
	smtpTls = environment.get("MAILPIT_TLS_SMTP", "31026");
	apiPlain = "http://127.0.0.1:" ~ environment.get("MAILPIT_API", "38025");
	apiTls = "http://127.0.0.1:" ~ environment.get("MAILPIT_TLS_API", "38026");

	writeln("non-loopback host: ", host);

	test!"To, Cc and Bcc receive the email, Bcc is not in the message"({
		new Email()
			.setFrom("sender@example.com", "Andrè Sender")
			.addTo("alice@example.com", "Alice")
			.addTo("bob@example.com")
			.addCc("carol@example.com", "Dr. Carol")
			.addBcc("hidden@example.com", "Hidden")
			.setSubject("Report")
			.setPlainTextBody("Hi")
			.send("smtp://localhost:" ~ smtpPlain);

		auto msg = onlyMessage(apiPlain);
		assert(addresses(msg["To"]) == ["alice@example.com", "bob@example.com"]);
		assert(addresses(msg["Cc"]) == ["carol@example.com"]);
		assert(addresses(msg["Bcc"]) == ["hidden@example.com"]); // in the envelope only
		assert(msg["From"]["Name"].str == "Andrè Sender", msg["From"].toString);
		assert(msg["Cc"].array[0]["Name"].str == "Dr. Carol");

		string raw = rawMessage(apiPlain, msg);
		assert(!raw.canFind("\nBcc:"));
		assert(!raw.canFind("\nBcc:"));
	});

	test!"Only Bcc recipients"({
		new Email()
			.setFrom("sender@example.com")
			.addBcc("one@example.com")
			.addBcc("two@example.com")
			.setSubject("Newsletter")
			.setPlainTextBody("Hi")
			.send("smtp://localhost:" ~ smtpPlain);

		auto msg = onlyMessage(apiPlain);
		assert(addresses(msg["Bcc"]) == ["one@example.com", "two@example.com"]);
		assert(msg["To"].array.length == 0);

		string raw = rawMessage(apiPlain, msg);
		assert(!raw.canFind("one@example.com") && !raw.canFind("two@example.com"));
	});

	test!"Subject, bodies, embedded files and attachments arrive intact"({
		string subject = "Città: perché è così? Un oggetto lungo, lungo, lungo, lungo, lungo, lungo 🎉";
		string text = "Prima riga\nè la seconda\n.\nuna riga con il punto qui sopra\n";
		string html = "<p>";
		foreach (i; 0 .. 200) html ~= "Ciao è <b>grassetto</b> ";
		html ~= "</p><img src=\"cid:logo\">";

		ubyte[] png = [0x89, 'P', 'N', 'G', 0, 1, 2, 255];

		new Email()
			.setFrom("sender@example.com")
			.addTo("alice@example.com")
			.setSubject(subject)
			.setPlainTextBody(text)
			.setHtmlBody(html)
			.addEmbeddedFile(png, "logo", "image/png")
			.addAttachment(cast(ubyte[])"a;b\n1;2\n", "text/csv", "relazione è \"finale\".csv")
			.send("smtp://localhost:" ~ smtpPlain);

		auto msg = onlyMessage(apiPlain);
		assert(msg["Subject"].str == subject, msg["Subject"].str);
		assert(msg["Text"].str.normalize == text.normalize, msg["Text"].str);
		assert(msg["HTML"].str.normalize == html, msg["HTML"].str);

		assert(msg["Inline"].array.length == 1);
		assert(msg["Inline"].array[0]["ContentID"].str == "logo");
		assert(msg["Inline"].array[0]["ContentType"].str == "image/png");

		auto attachments = msg["Attachments"].array;
		assert(attachments.length == 1);
		assert(attachments[0]["FileName"].str == "relazione è \"finale\".csv", attachments[0]["FileName"].str);
		assert(attachments[0]["ContentType"].str == "text/csv");

		auto part = get!(HTTP, ubyte)(apiPlain ~ "/api/v1/message/" ~ msg["ID"].str ~ "/part/" ~ msg["Inline"].array[0]["PartID"].str);
		assert(part == png);
	});

	test!"Header injection in the subject and names does not add headers"({
		new Email()
			.setFrom("sender@example.com", "Evil\r\nBcc: victim@example.com")
			.addTo("alice@example.com")
			.setSubject("Hello\r\nBcc: victim@example.com")
			.setPlainTextBody("Hi")
			.send("smtp://localhost:" ~ smtpPlain);

		auto msg = onlyMessage(apiPlain);
		assert(msg["Bcc"].array.length == 0);
		assert(addresses(msg["To"]) == ["alice@example.com"]);
	});

	test!"localhost with credentials and no STARTTLS: sent"({
		simpleEmail("Local auth").send("smtp://localhost:" ~ smtpPlain, "user", "password");
		assert(onlyMessage(apiPlain)["Subject"].str == "Local auth");
	});

	test!"Remote host with credentials and no STARTTLS offered: refused, password not sent"({
		assertThrown(simpleEmail("Must not arrive").send("smtp://" ~ host ~ ":" ~ smtpPlain, "user", "password"));
		assert(messages(apiPlain).length == 0);
	});

	test!"Remote host with credentials and STARTTLS: sent over TLS"({
		// The server requires STARTTLS: the email arrives only if postino switched to TLS
		simpleEmail("Over STARTTLS").send("smtp://" ~ host ~ ":" ~ smtpTls, "user", "password", selfSignedSmtp());
		assert(onlyMessage(apiTls)["Subject"].str == "Over STARTTLS");
	});

	test!"Remote host without credentials: plain SMTP, as before"({
		simpleEmail("Plain relay").send("smtp://" ~ host ~ ":" ~ smtpPlain);
		assert(onlyMessage(apiPlain)["Subject"].str == "Plain relay");
	});

	test!"Custom headers arrive, reserved ones can't be added"({
		simpleEmail("Headers")
			.addHeader("List-Unsubscribe", "<https://example.com/unsubscribe?id=42>, <mailto:unsubscribe@example.com>")
			.addHeader("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")
			.addHeader("X-Note", "perché sì")
			.send("smtp://localhost:" ~ smtpPlain);

		auto msg = onlyMessage(apiPlain);
		auto headers = parseJSON(fetch(apiPlain ~ "/api/v1/message/" ~ msg["ID"].str ~ "/headers"));
		assert(headers["List-Unsubscribe"].array[0].str == "<https://example.com/unsubscribe?id=42>, <mailto:unsubscribe@example.com>");
		assert(headers["List-Unsubscribe-Post"].array[0].str == "List-Unsubscribe=One-Click");
		assert(rawMessage(apiPlain, msg).canFind("X-Note: =?UTF-8?B?"));

		assertThrown!PostinoException(simpleEmail("x").addHeader("Bcc", "victim@example.com"));
	});

	test!"Internationalized domains are sent as punycode"({
		new Email()
			.setFrom("info@città.it", "Città")
			.addTo("ufficio@bücher.de")
			.setPlainTextBody("Hi")
			.send("smtp://localhost:" ~ smtpPlain);

		auto msg = onlyMessage(apiPlain);
		assert(msg["From"]["Address"].str == "info@xn--citt-3na.it");
		assert(addresses(msg["To"]) == ["ufficio@xn--bcher-kva.de"]);
	});

	test!"clone() and one connection for many emails"({
		auto newsletter = new Email().setFrom("news@example.com").setSubject("News").setPlainTextBody("Hi");
		auto smtp = SMTP();

		foreach (address; ["one@example.com", "two@example.com", "three@example.com"])
			newsletter.clone().addTo(address).send("smtp://localhost:" ~ smtpPlain, "", "", smtp);

		auto list = messages(apiPlain);
		assert(list.length == 3);

		foreach (m; list)
			assert(m["To"].array.length == 1 && (m["Bcc"].isNull || m["Bcc"].array.length == 0));
	});

	writeln("All Mailpit tests passed");
}

void test(string name)(void delegate() body)
{
	del(apiPlain ~ "/api/v1/messages");
	del(apiTls ~ "/api/v1/messages");
	body();
	writeln("ok - ", name);
}

Email simpleEmail(string subject)
{
	return new Email()
		.setFrom("sender@example.com")
		.addTo("alice@example.com")
		.setSubject(subject)
		.setPlainTextBody("Hi");
}

// Accept the self-signed certificate of the test server
SMTP selfSignedSmtp()
{
	auto smtp = SMTP();
	smtp.handle.set(CurlOption.ssl_verifypeer, 0);
	smtp.handle.set(CurlOption.ssl_verifyhost, 0);
	return smtp;
}

// Bytes as they are: std.net.curl.get takes a response without charset for Latin-1
string fetch(string url)
{
	return cast(string)get!(HTTP, ubyte)(url).idup;
}

JSONValue[] messages(string api)
{
	return parseJSON(fetch(api ~ "/api/v1/messages"))["messages"].array;
}

JSONValue onlyMessage(string api)
{
	auto list = messages(api);
	assert(list.length == 1, "expected one message, got " ~ list.length.to!string);
	return parseJSON(fetch(api ~ "/api/v1/message/" ~ list[0]["ID"].str));
}

// The message as postino sent it, without the Received header added by Mailpit
// (it can name a Bcc recipient: "for <hidden@example.com>")
string rawMessage(string api, JSONValue msg)
{
	import std.string : indexOf;

	string raw = fetch(api ~ "/api/v1/message/" ~ msg["ID"].str ~ "/raw");
	return raw[raw.indexOf("MIME-Version:") .. $];
}

string[] addresses(JSONValue list)
{
	return list.array.map!(a => a["Address"].str).array.sort.array;
}

string normalize(string s)
{
	import std.string : replace, stripRight;
	return s.replace("\r\n", "\n").stripRight;
}

// An address of this machine that is not loopback: the one used to reach the internet
string localAddress()
{
	import std.socket : UdpSocket, InternetAddress;

	auto socket = new UdpSocket();
	scope(exit) socket.close();
	socket.connect(new InternetAddress("192.0.2.1", 9)); // no packet is sent
	return socket.localAddress.toAddrString;
}
