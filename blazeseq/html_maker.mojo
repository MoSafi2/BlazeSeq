import base64
import python
from python import PythonObject, Python
from utils import Variant


trait HTMLMaker(CollectionElement):
    fn html_output(self) -> String:
        ...


@value
struct result_panel:
    var name: String
    var grade: String
    var legand: String
    var html_output: String


fn create_html_template() -> String:
    return """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Image Container</title>
        <link rel="stylesheet" href="style.css">
    </head>
    <body>
        <div class="image-container">
        </div>
    </body>
    </html>
    """


fn insert_image_into_template(
    owned html: String, base64_image: String, plot_info: result_panel
) raises -> String:
    """
    Inserts a base64-encoded image into the HTML template.

    Args:
        html: The HTML template string.
        base64_image: The base64-encoded image string.
        plot_info: Info about the plot.

    Returns:
        String: The updated HTML template with the image inserted.
    """
    # var py_str: PythonObject = '<img src="data:image/jpeg;base64,{}" alt="Image">'
    # var image_html: PythonObject = py_str.format(base64_image)

    var marker: String = '<div class="image-container">'
    if marker in html:
        html = html.replace(
            marker,
            '<img src="data:image/jpeg;base64,'
            + base64_image
            + '" alt="Image">'
            + "\n"
            + "</div>"
            + marker,
        )
    return html


@always_inline
fn _make_summary_insert(panel: result_panel) raises -> String:
    return '<li><a class="{}" href="#{}">{}</a></li>'.format(
        panel.grade, panel.name, panel.legand
    )


@always_inline
fn _make_module_insert(panel: result_panel) raises -> String:
    return """
            <div class="module">
                <h2 class="{0}" id="{1}">
                    {2}
                </h2>
                <div id="{2}plot">
                <img src="data:image/jpeg;base64,{3}" alt="Image">
                </div>
            </div>

                  """.format(
        panel.grade, panel.name, panel.legand, panel.html_output
    )


@always_inline
fn insert_to_summary(mut html: String, insert: String) -> String:
    var pos = html.find("</ul>", start=html.find("<ul>"))
    first_part = html[:pos]
    last_part = html[pos:]
    return first_part + insert + last_part


@always_inline
fn insert_module(mut html: String, insert: String) -> String:
    var end_tag = html.find('<div class="footer">')
    var pos: Int = 0

    while html.find("</div>", start=pos) < end_tag:
        pos = html.find("</div>", start=pos) + 1

    first_part = html[: pos - 1]
    last_part = html[pos - 1 :]
    return first_part + insert + last_part


@always_inline
fn insert_result_panel(mut html: String, result: result_panel) raises -> String:
    summary = _make_summary_insert(result)
    module = _make_module_insert(result)

    html = insert_to_summary(html, summary)
    html = insert_module(html, module)

    return html
