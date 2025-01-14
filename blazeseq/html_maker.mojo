import base64
import python
from python import PythonObject, Python
from utils import Variant


alias encoded_imgs = Variant[String, List[String]]


fn create_html_template() -> String:
    return """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Image Container</title>
        <style>
            .image-container {
                display: flex;
                flex-wrap: wrap;
                gap: 10px;
            }
            .image-container img {
                max-width: 200px;
                max-height: 200px;
                border: 1px solid #ccc;
                padding: 5px;
            }
        </style>
    </head>
    <body>
        <div class="image-container">
        </div>
    </body>
    </html>
    """


fn insert_image_into_template(
    owned html: String, base64_image: String
) raises -> String:
    """
    Inserts a base64-encoded image into the HTML template.

    Args:
        html: The HTML template string.
        base64_image: The base64-encoded image string.

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
            + marker,
        )
    return html
