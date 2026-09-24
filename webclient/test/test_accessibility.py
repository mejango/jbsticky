"""Check the public document's native controls and accessible names."""

from html.parser import HTMLParser
from pathlib import Path
import unittest


class Document(HTMLParser):
    def __init__(self, source):
        super().__init__()
        self.nodes = []
        self.parents = []
        self.feed(source)

    def handle_starttag(self, tag, attrs):
        node = {"tag": tag, "attrs": dict(attrs), "parents": list(self.parents), "text": ""}
        self.nodes.append(node)
        if tag not in {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}:
            self.parents.append(node)

    def handle_endtag(self, tag):
        for index in range(len(self.parents) - 1, -1, -1):
            if self.parents[index]["tag"] == tag:
                del self.parents[index:]
                break

    def handle_data(self, data):
        for parent in self.parents:
            parent["text"] += data


class AccessibilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = Document((Path(__file__).resolve().parents[1] / "index.html").read_text())
        cls.ids = {node["attrs"]["id"]: node for node in cls.document.nodes if "id" in node["attrs"]}

    def name(self, node):
        attrs = node["attrs"]
        if attrs.get("aria-label"):
            return attrs["aria-label"]
        if attrs.get("aria-labelledby"):
            return " ".join(self.ids[identifier]["text"] for identifier in attrs["aria-labelledby"].split())
        labels = [label for label in self.document.nodes if label["tag"] == "label"
                  and ((attrs.get("id") and label["attrs"].get("for") == attrs["id"])
                       or any(parent is label for parent in node["parents"]))]
        return " ".join(label["text"] for label in labels)

    def test_every_form_control_has_an_accessible_name(self):
        for node in self.document.nodes:
            if node["tag"] not in {"input", "select", "textarea"}:
                continue
            with self.subTest(control=node["attrs"].get("id")):
                self.assertTrue(self.name(node).strip())

    def test_dialogs_are_named_by_their_headings(self):
        for node in self.document.nodes:
            if node["tag"] == "dialog":
                with self.subTest(dialog=node["attrs"].get("id")):
                    self.assertTrue(self.name(node).strip())

    def test_core_choices_use_native_keyboard_controls(self):
        for identifier in ("r-origin", "unstake-max", "stake-balance", "sort-largest", "sort-longest", "cd-audit"):
            with self.subTest(control=identifier):
                self.assertIn(self.ids[identifier]["tag"], {"button", "select"})
        for node in self.document.nodes:
            attrs = node["attrs"]
            if any(key in attrs for key in ("data-v", "data-as-cooldown", "data-as-allowance")):
                with self.subTest(choice=node["text"]):
                    self.assertEqual(node["tag"], "button")
                    self.assertEqual(attrs.get("type"), "button")
                    self.assertIn(attrs.get("aria-pressed"), {"true", "false"})

    def test_document_does_not_require_inline_script_permissions(self):
        for node in self.document.nodes:
            with self.subTest(tag=node["tag"], identifier=node["attrs"].get("id")):
                self.assertFalse(any(key.startswith("on") for key in node["attrs"]))
                if node["tag"] == "script":
                    self.assertTrue(node["attrs"].get("src"))
                    self.assertFalse(node["text"].strip())


if __name__ == "__main__":
    unittest.main()
