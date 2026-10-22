import unittest

from notes import page


class RenderTitleTest(unittest.TestCase):
    def test_title_is_wrapped_in_h1(self):
        self.assertEqual(page.render_title(), "<h1>" + page.TITLE + "</h1>")


if __name__ == "__main__":
    unittest.main()
