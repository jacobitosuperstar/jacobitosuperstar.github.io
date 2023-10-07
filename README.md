# WEBPAGE STRUCTURE

Change of mindset, first we should be able to show the blog first, and change
the about page to my CV, in the modulo I should add my work XP and content
modules instead of trying to put the WebPage as my CV first then the blog posts

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
