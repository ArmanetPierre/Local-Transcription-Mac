"""Tests des metriques du banc (scripts/bench/run_bench.py)."""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(HERE, "..", "..", "scripts", "bench")))

import run_bench as bench  # noqa: E402


def seg(start, end, speaker, text=""):
    return {"start": start, "end": end, "speaker": speaker, "text": text}


class NormalizeTests(unittest.TestCase):
    def test_lowercase_punctuation_apostrophes(self):
        self.assertEqual(bench.normalize_words("C’est l'été, d'accord ?"),
                         ["c", "est", "l", "été", "d", "accord"])

    def test_fillers_removed(self):
        self.assertEqual(bench.normalize_words("So uh we euh decided, um, yes"), ["so", "we", "decided", "yes"])

    def test_hyphens_split(self):
        self.assertEqual(bench.normalize_words("peut-être"), ["peut", "être"])


class TextQualityTests(unittest.TestCase):
    def test_punctuation_rate(self):
        self.assertAlmostEqual(bench.punctuation_rate([seg(0, 1, "A", "Oui. Non ? Peut-être")]), 200 / 4)
        self.assertEqual(bench.punctuation_rate([seg(0, 1, "A", "sans ponctuation du tout")]), 0)

    def test_max_repeat(self):
        self.assertEqual(bench.max_repeat([seg(0, 1, "A", "ok ok ok ok ok ok ok")]), 4)
        self.assertEqual(bench.max_repeat([seg(0, 1, "A", "une phrase normale sans boucle")]), 1)


class WerTests(unittest.TestCase):
    def test_identical(self):
        self.assertEqual(bench.wer([seg(0, 1, "A", "bonjour à tous")], [seg(0, 1, "B", "Bonjour à tous.")]), 0)

    def test_one_substitution_out_of_four(self):
        ref = [seg(0, 1, "A", "la réserve légale minimum")]
        hyp = [seg(0, 1, "A", "la réserve totale minimum")]
        self.assertAlmostEqual(bench.wer(ref, hyp), 0.25)

    def test_insertions_and_deletions(self):
        self.assertEqual(bench.word_errors(["a", "b", "c"], ["a", "c", "d"]), 2)

    def test_empty_reference(self):
        self.assertIsNone(bench.wer([seg(0, 1, "A", "")], [seg(0, 1, "A", "x")]))


class SpeakerMappingTests(unittest.TestCase):
    def test_label_permutation_is_not_an_error(self):
        ref = [seg(0, 5, "SPEAKER_00"), seg(5, 10, "SPEAKER_01")]
        hyp = [seg(0, 5, "SPEAKER_01"), seg(5, 10, "SPEAKER_00")]
        mapping, err = bench.speaker_mapping(ref, hyp, 10)
        self.assertEqual(mapping, {"SPEAKER_01": "SPEAKER_00", "SPEAKER_00": "SPEAKER_01"})
        self.assertAlmostEqual(err, 0.0)

    def test_confusion_rate(self):
        ref = [seg(0, 10, "A")]
        hyp = [seg(0, 7, "X"), seg(7, 10, "Y")]
        _, err = bench.speaker_mapping(ref, hyp, 10)
        self.assertAlmostEqual(err, 0.3, places=1)

    def test_unlabeled_segments_ignored(self):
        ref = [seg(0, 5, "A"), seg(5, 10, "Inconnu")]
        hyp = [seg(0, 10, "X")]
        _, err = bench.speaker_mapping(ref, hyp, 10)
        self.assertAlmostEqual(err, 0.0)


class EvaluateRecognitionTests(unittest.TestCase):
    def test_counts_correct_and_wrong_names(self):
        ref = {"id": "r", "duration_sec": 10, "role": "recognize",
               "speaker_names": {"S0": "Olivier", "S1": "Pierre"},
               "segments": [seg(0, 5, "S0", "a"), seg(5, 10, "S1", "b")]}
        result = {"segments": [seg(0, 5, "H1", "a"), seg(5, 10, "H0", "b")],
                  "speaker_matches": {"H1": "Olivier", "H0": "Marie"}}
        gallery = {"Olivier": [[1.0, 0.0]], "Pierre": [[0.0, 1.0]]}
        result["speaker_embeddings"] = {"H1": [1.0, 0.1], "H0": [0.1, 1.0]}
        rec = bench.evaluate(ref, result, {}, 1.0, gallery)["recognition"]
        self.assertEqual((rec["correct"], rec["expected"], rec["wrong"]), (1, 2, 1))
        self.assertEqual(rec["details"]["H0"]["truth"], "Pierre")
        self.assertGreater(rec["details"]["H0"]["score_truth"], 0.9)

    def test_unknown_voices_are_not_expected(self):
        ref = {"id": "r", "duration_sec": 10, "role": "recognize",
               "speaker_names": {"S0": "Olivier", "S1": "Moh"},
               "segments": [seg(0, 5, "S0", "a"), seg(5, 10, "S1", "b")]}
        result = {"segments": [seg(0, 5, "H0", "a"), seg(5, 10, "H1", "b")],
                  "speaker_matches": {"H0": "Olivier"}}
        rec = bench.evaluate(ref, result, {}, 1.0, {"Olivier": [[1.0]]})["recognition"]
        self.assertEqual((rec["correct"], rec["expected"], rec["wrong"]), (1, 1, 0))


class GalleryTests(unittest.TestCase):
    def test_enroll_multi_appends_and_single_replaces(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "gallery.json")
            result = {"speaker_embeddings": {"H0": [1.0, 0.0]}}
            bench.enroll(path, "a", result, {"H0": "S0"}, {"S0": "Pierre"}, "multi")
            bench.enroll(path, "b", result, {"H0": "S0"}, {"S0": "Pierre"}, "multi")
            self.assertEqual(len(bench.load_gallery(path)["Pierre"]), 2)
            bench.enroll(path, "c", result, {"H0": "S0"}, {"S0": "Pierre"}, "single")
            self.assertEqual(len(bench.load_gallery(path)["Pierre"]), 1)


if __name__ == "__main__":
    unittest.main()
