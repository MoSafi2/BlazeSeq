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
    var panel_type: String

    fn __init__(
        out self,
        name: String,
        grade: String,
        legand: String,
        html_output: String,
        panel_type: String = "image",
    ):
        self.name = name
        self.grade = grade
        self.legand = legand
        self.html_output = html_output
        self.panel_type = panel_type


@always_inline
fn _make_summary_insert(panel: result_panel) raises -> String:
    return '<li><a class="{}" href="#{}">{}</a></li>'.format(
        panel.grade, panel.name, panel.legand
    )


@always_inline
fn _make_module_insert(panel: result_panel) raises -> String:
    if panel.panel_type == "image":
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
    elif panel.panel_type == "table":
        return """
                <div class="module">
                    <h2 class="{0}" id="{1}">
                        {2}
                    </h2>
                    <div id="{2}plot">
                    {3}
                    </div>
                </div>
                 
                    """.format(
            panel.grade, panel.name, panel.legand, panel.html_output
        )

    else:
        return """
            """


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


fn _make_row(
    seq: String, count: Int, perc: Float64, source: String
) raises -> String:
    return row_template.format(seq, count, perc, source)


fn _make_table(rows: String) raises -> String:
    return table_template.replace(String("<<rows>>"), rows)


alias row_template: String = """
    <tr>
        <td>{}</td>
        <td>{}</td>
        <td>{}%</td>
        <td>{}</td>
    </tr>
    """

alias table_template: String = """
    <table>
    <thead>
        <tr>
            <th>Sequence</th>
            <th>Count</th>
            <th>Percentage</th>
            <th>Possible Source</th>
        </tr>
    </thead>
    <tbody>
        <<rows>>
    </tbody>
    </table>
    """


# Ported from FastQC: https://github.com/s-andrews/FastQC/blob/1faeea0412093224d7f6a07f777fad60a5650795/uk/ac/babraham/FastQC/Modules/BasicStats.java#L157
fn format_length(original_length: Float64) -> String:
    length = original_length
    unit = " bp"

    if length >= 1000000000:
        length /= 1000000000
        unit = " Gbp"
    elif length >= 1000000:
        length /= 1000000
        unit = " Mbp"
    elif length >= 1000:
        length /= 1000
        unit = " kbp"

    chars = String(length)

    last_index = 0

    # Go through until we find a dot (if there is one)
    for i in range(len(chars)):
        last_index = i
        if chars[i] == ".":
            break

    # We keep the next char as well if they are non-zero numbers
    if last_index + 1 < len(chars) and chars[last_index + 1] != "0":
        last_index += 1
    elif last_index > 0 and chars[last_index] == ".":
        last_index -= 1  # Lose the dot if it's the last character

    final_chars = chars[: last_index + 1]  # Slice the list

    return final_chars + unit  # Join the characters back into a string


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
        """ + style + """
        </style>
        <script src="https://cdn.plot.ly/plotly-latest.min.js"></script>
    </head>

    <body>
        <div class="header">
            <div id="header_title">Report</div>
            <div id="header_filename">
                <<date>><br />
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

        <div class="footer">BlazeQC<<BlazeQC_Version>></div>
    </body>
    <script src="https://code.jquery.com/jquery-3.3.1.slim.min.js" crossorigin="anonymous"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/popper.js/1.14.7/umd/popper.min.js"
        crossorigin="anonymous"></script>
    <script src="https://stackpath.bootstrapcdn.com/bootstrap/4.3.1/js/bootstrap.min.js" crossorigin="anonymous"></script>
    </html>
            """

alias style: String = """
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
                """
