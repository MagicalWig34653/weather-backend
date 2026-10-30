import io
import unittest

from PIL import Image

from radar_ingest import validate
from tests.helpers import png_bytes

XML = (b'<?xml version="1.0"?><ServiceExceptionReport><ServiceException code="InvalidDimensionValue">'
       b"Could not find a match for time</ServiceException></ServiceExceptionReport>")


class ValidateTests(unittest.TestCase):
    def test_valid_png_roundtrips_losslessly_to_webp(self):
        data = png_bytes(256, 328, 5)
        image = validate.validate_png(data, 256, 328)
        webp = validate.to_webp(image)
        back = Image.open(io.BytesIO(webp)).convert("RGBA")
        self.assertEqual(back.tobytes(), image.tobytes())
        self.assertLess(len(webp), len(data))

    def test_rejects_xml_error_with_http_200_body(self):
        with self.assertRaises(validate.InvalidImage):
            validate.validate_png(XML * 5, 256, 328)

    def test_rejects_wrong_size_truncated_and_garbage(self):
        good = png_bytes(256, 328)
        with self.assertRaises(validate.InvalidImage):
            validate.validate_png(good, 512, 656)
        with self.assertRaises(validate.InvalidImage):
            validate.validate_png(good[:600] + b"\0" * 600, 256, 328)
        with self.assertRaises(validate.InvalidImage):
            validate.validate_png(b"\x00" * 2000, 256, 328)
        with self.assertRaises(validate.InvalidImage):
            validate.validate_png(b"\x89PNG\r\n\x1a\n", 256, 328)  # too small


if __name__ == "__main__":
    unittest.main()
