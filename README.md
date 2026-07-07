# WEBPAGE STRUCTURE

Change of mindset, first we should be able to show the blog first, and change
the about page to my CV, in the modulo I should add my work XP and content
modules instead of trying to put the WebPage as my CV first then the blog posts

## CODE BLOCK RENDERING

Hugo uses [Chroma](https://github.com/alecthomas/chroma) for syntax highlighting. Configuration lives in `config.toml` under `[markup.highlight]`.

### Changing the color theme

```toml
[markup.highlight]
  style = 'modus-vivendi'  # change this to any Chroma theme
```

List all available themes: `hugo gen chromastyles --help`
Preview them at: https://xyproto.github.io/splash/docs/

### Two rendering modes

**Inline styles** (`noClasses = true`, default):
- Chroma bakes color values directly into the HTML as `style=""` attributes.
- No extra CSS file needed.
- Downside: you cannot override the background or colors from your own CSS (inline styles win).

**Class-based** (`noClasses = false`, what this site uses):
- Chroma outputs CSS class names instead of inline styles.
- With no chroma stylesheet loaded, code renders as plain text inheriting
  the page colors (transparent background, adapts to light/dark theme).
- To get token colors back, generate and load a CSS file:
  ```bash
  hugo gen chromastyles --style=tango > assets/css/syntax.css
  ```
  Then link it in `layouts/partials/head.html`:
  ```html
  {{ $syntax := resources.Get "css/syntax.css" | minify | fingerprint }}
  <link href="{{ $syntax.Permalink }}" rel="stylesheet">
  ```
- Upside: you can override anything (background, colors, font) from `main.css` using normal CSS specificity.

### Customizing code block appearance (class-based mode only)

```css
/* transparent background */
.chroma { background-color: transparent !important; }

/* custom font */
pre, code { font-family: 'Comic Mono', monospace; }

/* responsive font size */
pre { font-size: clamp(0.65rem, 0.5rem + 0.5vw, 0.75rem); }
```

### Changing the font

Add the font in `layouts/partials/head.html` (Google Fonts or CDN), then set it in CSS:
```css
pre, code { font-family: 'Your Font', monospace; }
```

## SNIPPEDS

```log

{{ $image := .Resources.GetMatch .Params.image }}
{{ if $image }}
<img class="img-fluid" src="{{ (  $image.Crop "2048x450 webp Center q100" ).RelPermalink }}">
{{ else }}
<h2>{{ .Title }}</h2>
{{ end }}
```

Takes the image from the image parameter. The image is in the same folder of
the history. Thats a neat little trick.
