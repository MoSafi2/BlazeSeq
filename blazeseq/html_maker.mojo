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


alias html_template: String = """
    <html>
    <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no">
        <title><<filename>> - report</title>
        <link rel="stylesheet" href="https://stackpath.bootstrapcdn.com/bootstrap/4.3.1/css/bootstrap.min.css"
            integrity="sha384-ggOyR0iXCbMQv3Xipma34MD+dH/1fQ784/j6cY/iJTQUOhcWr7x9JvoRxT2MZw1T" crossorigin="anonymous">
        <link href="https://stackpath.bootstrapcdn.com/font-awesome/4.7.0/css/font-awesome.min.css" rel="stylesheet"
            integrity="sha384-wvfXpqpZZVQGK6TAh5PVlGOfQNHSoD2xbE+QkPxCAFlNEevoEH3Sl0sibVcOQVnN" crossorigin="anonymous">
        <style>
            @media screen {
                div.summary {
                    width: 18em;
                    position: fixed;
                    top: 4em;
                    margin: 1em 0 0 1em;
                }

                div.main {
                    display: block;
                    position: absolute;
                    overflow: auto;
                    height: auto;
                    width: auto;
                    top: 4.5em;
                    bottom: 2.3em;
                    left: 18em;
                    right: 0;
                    border-left: 1px solid #CCC;
                    padding: 0 0 0 1em;
                    background-color: white;
                    z-index: 1;
                }

                div.header {
                    background-color: #EEE;
                    border: 0;
                    margin: 0;
                    padding: 0.2em;
                    font-size: 200%;
                    position: fixed;
                    width: 100%;
                    top: 0;
                    left: 0;
                    z-index: 2;
                }

                div.footer {
                    background-color: #EEE;
                    border: 0;
                    margin: 0;
                    padding: 0.5em;
                    height: 2.5em;
                    overflow: hidden;
                    font-size: 100%;
                    position: fixed;
                    bottom: 0;
                    width: 100%;
                    z-index: 2;
                }

                img.indented {
                    margin-left: 3em;
                }
            }

            @media print {
                img {
                    max-width: 100% !important;
                    page-break-inside: avoid;
                }

                h2,
                h3 {
                    page-break-after: avoid;
                }

                div.header {
                    background-color: #FFF;
                }
            }

            body {
                color: #000;
                background-color: #FFF;
                border: 0;
                margin: 0;
                padding: 0;
            }

            div.header {
                border: 0;
                margin: 0;
                padding: 0.5em;
                font-size: 200%;
                width: 100%;
            }

            #header_title {
                display: inline-block;
                float: left;
                clear: left;
            }

            #header_filename {
                display: inline-block;
                float: right;
                clear: right;
                font-size: 50%;
                margin-right: 2em;
                text-align: right;
            }

            div.header h3 {
                font-size: 50%;
                margin-bottom: 0;
            }

            div.summary ul {
                padding-left: 0;
                list-style-type: none;
            }

            div.summary ul li img {
                margin-bottom: -0.5em;
                margin-top: 0.5em;
            }

            div.main {
                background-color: white;
            }

            div.module {
                padding-bottom: 3em;
                padding-top: 3em;
                border-bottom: 1px solid #990000;
            }

            div.footer {
                background-color: #EEE;
                border: 0;
                margin: 0;
                padding: 0.5em;
                font-size: 100%;
                width: 100%;
            }

            h2 {
                color: #2a5e8c;
                padding-bottom: 0;
                margin-bottom: 0;
                clear: left;
            }

            table {
                margin-left: 3em;
                text-align: center;
            }

            th {
                text-align: center;
                background-color: #000080;
                color: #FFF;
                padding: 0.4em;
            }

            td {
                font-family: monospace;
                text-align: left;
                background-color: #EEE;
                color: #000;
                padding: 0.4em;
            }

            img {
                padding-top: 0;
                margin-top: 0;
                border-top: 0;
            }

            p {
                padding-top: 0;
                margin-top: 0;
            }

            .pass {
                color: #009900;
            }

            .warn {
                color: #999900;
            }

            .fail {
                color: #990000;
            }
        </style>
        <script src="https://cdn.plot.ly/plotly-latest.min.js"></script>
    </head>

    <body>
        <div class="header">
            <div id="header_title">Report</div>
            <div id="header_filename">
                {{date}}<br />
                <<filename>>
            </div>
        </div>
        <div class="summary">
            <h2>Summary</h2>
            <ul>
                <!-- Insert Point for Summary links -->
            </ul>
        </div>

        <div class="main">
            <!-- Insertion point for Images & Results -->
        </div>

        <div class="footer">Falco {{FalcoConfig::FalcoVersion}}</div>
    </body>
    <script src="https://code.jquery.com/jquery-3.3.1.slim.min.js" crossorigin="anonymous"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/popper.js/1.14.7/umd/popper.min.js"
        crossorigin="anonymous"></script>
    <script src="https://stackpath.bootstrapcdn.com/bootstrap/4.3.1/js/bootstrap.min.js" crossorigin="anonymous"></script>
    </html>
"""
