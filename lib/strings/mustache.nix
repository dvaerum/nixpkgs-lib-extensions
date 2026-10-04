{ lib, ... }:
{
  /**
    Render a [Mustache](https://mustache.github.io/) template against a
    view (an attrset of values). A thin wrapper around a vendored,
    third-party, pure-Nix Mustache implementation -- see
    `internal/mustache/ACKNOWLEDGEMENT.md` for provenance, license, and
    why it is vendored rather than pulled in as a flake input.

    Supports the full core Mustache spec plus lambdas: variables
    (`{{escaped}}`, `{{&unescaped}}`, `{{{unescaped}}}`), sections
    (`{{#section}}`), inverted sections (`{{^inverted}}`), comments
    (`{{!comment}}`), dot-path variables (`{{obj.prop}}`), partials
    (`{{>partial}}`), lambdas, and custom delimiters (`{{=<% %>=}}`).

    # Type

    ```
    renderMustache :: { template :: String | Path, view :: AttrSet, config :: AttrSet } -> String
    ```

    # Arguments

    template
    : The template itself, as a string, OR a path to a template file
    : (read with `readFile`) -- e.g. `./Corefile.mustache`.

    view
    : An attrset of values the template's `{{tags}}` resolve against.
    : A value may be a function (a lambda section/variable, per the
    : Mustache spec) -- state across multiple calls is not supported:
    : Nix has no mutable state to hold it.

    config.escape
    : Applied to every ESCAPED (`{{tag}}`) substitution. Defaults to the
    : identity function (no escaping) -- pass e.g. nixpkgs'
    : `lib.strings.escapeXML` for HTML/XML output.

    config.partial
    : `name: template-string-or-null` -- resolves a `{{>partial}}` tag by
    : name. Defaults to a function returning `null` (no partials
    : resolve).

    # Example

    ```nix
    renderMustache { template = "Hello, {{name}}!"; view = { name = "nix"; }; }
    => "Hello, nix!"

    renderMustache {
      template = "{{#items}}- {{.}}\n{{/items}}";
      view = { items = [ "a" "b" "c" ]; };
    }
    => "- a\n- b\n- c\n"
    ```
  */
  renderMustache = import ./internal/mustache { inherit lib; };
}
