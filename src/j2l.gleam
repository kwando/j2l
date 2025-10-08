import contour
import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleam/string
import gleam/uri.{type Uri}
import jot
import lustre
import lustre/attribute.{class}
import lustre/effect
import lustre/element
import lustre/element/html
import lustre/event
import modem

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = app |> lustre.start("#app", Nil)

  Nil
}

type Msg {
  OnRouteChange(Route)
  UserUpdatedJotContent(String)
  UserSubmitted

  Noop
  UserToggledDetails
}

type Model {
  Model(
    input: String,
    output: String,
    html_output: String,
    jot_doc: String,
    gleam_code: String,
    skip_prefix: Bool,
    show_details: Bool,
  )
}

fn init(_flags) {
  let options =
    modem.initial_uri()
    |> result.try(jot_content)
    |> result.unwrap(QueryOptions("", False))

  #(
    Model(
      input: options.content,
      output: "",
      html_output: "",
      jot_doc: "",
      gleam_code: "",
      skip_prefix: False,
      show_details: options.show_details,
    )
      |> render_output,
    modem.init(on_url_change),
  )
}

fn update(model: Model, value: Msg) -> #(Model, effect.Effect(a)) {
  case value {
    OnRouteChange(EditorRoute(content)) -> {
      #(Model(..model, input: content), effect.none())
    }
    UserUpdatedJotContent(content) ->
      Model(..model, input: content)
      |> render_output()
      |> sync_url

    UserToggledDetails ->
      Model(..model, show_details: !model.show_details)
      |> sync_url
    UserSubmitted -> {
      model
      |> render_output
      |> sync_url
    }
    Noop -> #(model, effect.none())
  }
}

fn sync_url(model: Model) {
  #(
    model,
    modem.replace(
      "/",
      option.Some(
        "content="
        <> uri.percent_encode(model.input)
        <> "&details="
        <> model.show_details |> bool.to_string,
      ),
      None,
    ),
  )
}

type LustreElement {
  LustreElement(
    tag: String,
    attributes: List(#(String, String)),
    children: List(LustreElement),
  )
  LustreSelfClosingElement(tag: String, attributes: List(#(String, String)))
  LustreUnsafe(
    namespace: String,
    tag: String,
    attributes: List(#(String, String)),
    content: String,
  )
  LustreText(content: String)
}

fn render_output(model: Model) -> Model {
  let doc = jot.parse(model.input)

  let lustre_code =
    doc_to_lustre(doc)
    |> list.map(render_lustre_loop(_, 1, model.skip_prefix))
    |> string.join(",\n")

  Model(
    ..model,
    output: lustre_code,
    html_output: jot.document_to_html(doc),
    jot_doc: string.inspect(doc),
    gleam_code: contour.to_html("[\n" <> lustre_code <> "\n]"),
  )
}

fn doc_to_lustre(doc: jot.Document) -> List(LustreElement) {
  list.map(doc.content, container_to_lustre)
}

fn container_to_lustre(container: jot.Container) -> LustreElement {
  case container {
    jot.BlockQuote(attributes:, items:) -> todo as "BlockQuote"
    jot.BulletList(layout:, style:, items:) ->
      LustreElement(
        "ul",
        [],
        list.map(items, fn(item) {
          LustreElement("li", [], list.map(item, container_to_lustre))
        }),
      )
    jot.Codeblock(attributes:, language:, content:) ->
      LustreElement("pre", [], [
        LustreText(content |> string.replace("\"", "\\\"")),
      ])
    jot.Heading(attributes:, level:, content:) ->
      LustreElement(
        "h" <> int.to_string(level),
        [],
        list.map(content, inline_to_lustre),
      )
    jot.Paragraph(attributes:, content:) ->
      LustreElement("p", [], list.map(content, inline_to_lustre))
    jot.RawBlock(content:) -> LustreUnsafe("html", "div", [], content)
    jot.ThematicBreak -> LustreSelfClosingElement("hr", [])
  }
}

fn inline_to_lustre(inline: jot.Inline) -> LustreElement {
  case inline {
    jot.Code(content:) -> LustreElement("code", [], [LustreText(content:)])
    jot.Emphasis(content:) ->
      LustreElement("em", [], list.map(content, inline_to_lustre))
    jot.Footnote(reference:) -> todo as "Footnote"
    jot.Image(content:, destination:) ->
      LustreSelfClosingElement("img", [
        #("src", case destination {
          jot.Reference(ref) -> ref
          jot.Url(url) -> url
        }),
      ])
    jot.Linebreak -> todo as "Linebreak"
    jot.Link(content:, destination:) -> {
      case destination {
        jot.Reference(_) -> todo
        jot.Url(href) ->
          LustreElement(
            "a",
            [#("href", href)],
            list.map(content, inline_to_lustre),
          )
      }
    }

    jot.MathDisplay(content:) -> todo as "MathDisplay"
    jot.MathInline(content:) -> todo as "MathInline"
    jot.NonBreakingSpace -> todo as "NonBreakingSpace"
    jot.Strong(content:) ->
      LustreElement("strong", [], list.map(content, inline_to_lustre))
    jot.Text(txt) -> LustreText(txt)
  }
}

fn render_attributes(attrs: List(#(String, String))) {
  case attrs {
    [] -> "[]"
    attrs ->
      "["
      <> list.fold(attrs, "", fn(acc, kv) {
        let #(key, value) = kv
        acc <> "attribute." <> key <> "(" <> string.inspect(value) <> ")"
      })
      <> "]"
  }
}

fn render_lustre_loop(element: LustreElement, level: Int, skip_prefix: Bool) {
  let indention = string.repeat("  ", level)
  case element {
    LustreElement(tag:, attributes:, children:) -> {
      indention
      <> case skip_prefix {
        False -> "html."
        True -> ""
      }
      <> tag
      <> "("
      <> render_attributes(attributes)
      <> ", [\n"
      <> list.map(element.children, fn(child) {
        render_lustre_loop(child, level + 1, skip_prefix)
      })
      |> string.join(",\n")
      <> "\n"
      <> indention
      <> "])"
    }
    LustreSelfClosingElement(tag, attributes) -> {
      indention
      <> case skip_prefix {
        False -> "html."
        True -> ""
      }
      <> tag
      <> "("
      <> render_attributes(attributes)
      <> ")"
    }
    LustreText(content:) ->
      indention
      <> {
        case skip_prefix {
          False -> "html.text(\""
          True -> "text(\""
        }
      }
      <> content
      <> "\")"
    LustreUnsafe(namespace:, tag:, attributes:, content:) ->
      indention
      <> "element.unsafe_raw_html("
      <> string.inspect(namespace)
      <> ", "
      <> string.inspect(tag)
      <> ", "
      <> render_attributes(attributes)
      <> ", "
      <> string.inspect(content)
      <> ")"
  }
}

fn on_url_change(uri: Uri) -> Msg {
  case jot_content(uri) {
    Error(_) -> ""
    Ok(options) -> options.content
  }
  |> EditorRoute
  |> OnRouteChange
}

type Route {
  EditorRoute(content: String)
}

fn drawer(content, visible, toggle) {
  html.details(
    [
      case visible {
        True -> attribute.attribute("open", "")
        False -> attribute.none()
      },
    ],
    [
      html.summary(
        [
          event.prevent_default(event.on_click(toggle)),
          class("text-cyan-500 cursor-pointer font-bold select-none"),
        ],
        [
          html.text("Details"),
        ],
      ),
      ..content
    ],
  )
}

fn view(model: Model) {
  html.div([class("p-4")], [
    heading("Jot2Lustre"),
    html.div([class("grid grid-cols-2 gap-4")], [
      text_area(model.input, UserUpdatedJotContent, fn(_) { UserSubmitted }),
      element.unsafe_raw_html("html", "pre", [class("gleam")], model.gleam_code),
    ]),

    html.button(
      [
        event.on_click(UserSubmitted),
        attribute.attribute("rows", "20"),
        class(
          "px-4 py-2 inline-block bg-indigo-500 text-sky-50 font-bold cursor-pointer",
        ),
      ],
      [html.text("Submit")],
    ),

    heading("Output"),
    drawer(
      [
        html.div([class("flex w-full gap-4 h-80")], [
          text_area(model.output, ignore_input, ignore_input),
          text_area(model.html_output, ignore_input, ignore_input),
        ]),
        html.div([class("h-80 flex mt-4")], [
          text_area(model.jot_doc, ignore_input, ignore_input),
        ]),
      ],
      model.show_details,
      UserToggledDetails,
    ),

    html.div([class("prose prose-invert")], [
      element.unsafe_raw_html("html", "div", [], model.html_output),
    ]),
  ])
}

fn heading(text) {
  html.h1([class("font-bold text-xl text-cyan-400 mb-2 mt-4")], [
    html.text(text),
  ])
}

fn ignore_input(_) {
  Noop
}

fn text_area(value, on_change, on_submit) {
  html.textarea(
    [
      event.debounce(event.on_input(on_change), 500),
      event.on("keydown", {
        use meta <- decode.field("metaKey", decode.bool)
        use key_code <- decode.field("key", decode.string)
        use value <- decode.subfield(["target", "value"], decode.string)

        case meta, key_code {
          True, "Enter" -> decode.success(on_submit(value))
          _, _ -> decode.failure(Noop, "Msg")
        }
      }),
      class(
        "grow w-full px-4 py-2 bg-gray-800 text-slate-100 font-mono text-xs outline-none",
      ),
    ],
    value,
  )
}

type QueryOptions {
  QueryOptions(content: String, show_details: Bool)
}

fn jot_content(uri: Uri) -> Result(QueryOptions, Nil) {
  case
    uri.query
    |> option.unwrap("")
    |> uri.parse_query()
  {
    Error(_) -> Error(Nil)
    Ok(qp) -> {
      QueryOptions(
        content: qp |> qp_str("content", ""),
        show_details: qp |> qp_bool("details", False),
      )
      |> Ok
    }
  }
}

fn qp_str(query_params, name, default: String) {
  query_params |> list.key_find(name) |> result.unwrap(default)
}

fn qp_bool(query_params, name, default: Bool) {
  query_params
  |> list.key_find(name)
  |> result.try(parse_bool)
  |> result.unwrap(default)
}

fn parse_bool(input: String) -> Result(Bool, Nil) {
  case input {
    "true" | "True" -> Ok(True)
    "false" | "False" -> Ok(False)
    _ -> Error(Nil)
  }
}
