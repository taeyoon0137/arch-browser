#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

README_FILE="$ROOT_DIR/README.md"
PRESET_README_FILE="$ROOT_DIR/resources/README.preset.md"
PRESET_HERO_FILE="$ROOT_DIR/resources/readme-hero.preset.svg"
HERO_FILE="$ROOT_DIR/resources/readme-hero.svg"

if [ ! -f "$PRESET_README_FILE" ]; then
  echo "Error: README.preset.md file not found at $PRESET_README_FILE"
  exit 1
fi

if [ ! -f "$PRESET_HERO_FILE" ]; then
  echo "Error: readme-hero.preset.svg file not found at $PRESET_HERO_FILE"
  exit 1
fi

# The project's canonical URL, never the checkout's remote, which may be an SSH address, a fork, or a URL with credentials.
REPOSITORY_URL="https://github.com/taeyoon0137/arch-browser"

# Generate resources/readme-hero.svg:
# - embed any existing hero images as base64 data URIs
# - drop <image> tags for hero images that do not exist
perl -MMIME::Base64=encode_base64 -0pe '
  BEGIN {
    ($root_dir) = @ARGV;
    @ARGV = @ARGV[1..$#ARGV];

    %mime_by_ext = (
      jpg => "image/jpeg",
      jpeg => "image/jpeg",
      png => "image/png",
    );
  }

  sub embed_image {
    my ($tag, $file_name) = @_;
    my $path = "$root_dir/resources/$file_name";
    return "" unless -f $path;

    my ($ext) = $file_name =~ /\.([^.]+)$/;
    $ext = lc($ext // "");
    my $mime = $mime_by_ext{$ext};
    return "" unless $mime;

    open my $image, "<:raw", $path or die "Error: failed to read $path: $!";
    local $/;
    my $bytes = <$image>;
    close $image;

    my $data_uri = "data:$mime;base64," . encode_base64($bytes, "");
    $tag =~ s|href="\./\Q$file_name\E"|href="$data_uri"|;
    return $tag;
  }

  s|<image\b(?=[^>]*\bhref="\./([^"]+)")[^>]*/>|embed_image($&, $1)|ge;
' "$ROOT_DIR" "$PRESET_HERO_FILE" > "$HERO_FILE"

# Generate README.md:
# - substitute the repository URL
# - rewrite ../<dir> source paths to ./<dir> for the root-level README
perl -0pe '
  BEGIN {
    ($repository_url) = @ARGV;
    @ARGV = @ARGV[1..$#ARGV];
  }

  s/\$\{repositoryUrl\}/$repository_url/g;
  s|\.\./resources|./resources|g;
  s|\.\./scripts|./scripts|g;
  s|\.\./docs|./docs|g;
  s|\.\./AGENTS\.md|./AGENTS.md|g;
  s|\.\./CLAUDE\.md|./CLAUDE.md|g;
' "$REPOSITORY_URL" "$PRESET_README_FILE" > "$README_FILE"

echo "README.md and readme-hero.svg updated successfully"
