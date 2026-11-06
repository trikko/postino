#!/bin/sh
# Generate the html documentation in docs/ (served by GitHub Pages) with scod, the same skin
# as serverino, parserino, jape and pacchettino.
# docs/llms.txt, docs/llms-full.txt and docs/AGENTS.md are written by hand; docs/SKILL.md is
# generated from AGENTS.md.
# Usage: tools/docs.sh
set -e
cd "$(dirname "$0")/.."

dub build -q -b ddox
dub run -q scod -- generate-html --navigation-type=DeclarationTree \
    --sitemap-url=https://trikko.github.io/postino/ docs.json docs
rm -f docs.json __dummy.html

# served as they are: without this Jekyll turns SKILL.md, which has front matter, into html
touch docs/.nojekyll

# SKILL.md is AGENTS.md with the front matter that makes it an installable skill
{
    printf -- '---\nname: postino\n'
    printf 'description: Official reference for postino, the email library for the D programming language (MIME messages with plain text, HTML, embedded images and attachments, sent over SMTP with TLS or STARTTLS, or saved as .eml). Use it whenever the user asks about postino, or about sending email or SMTP in D.\n'
    printf -- '---\n\n'
    cat docs/AGENTS.md
} > docs/SKILL.md
echo "docs/ updated"
