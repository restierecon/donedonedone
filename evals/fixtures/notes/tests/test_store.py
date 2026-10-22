import unittest

from notes.store import NoteStore


class NoteStoreTest(unittest.TestCase):
    def test_new_store_is_constructible(self):
        self.assertIsInstance(NoteStore(), NoteStore)


if __name__ == "__main__":
    unittest.main()
