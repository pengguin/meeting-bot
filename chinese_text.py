from functools import lru_cache

from opencc import OpenCC


@lru_cache(maxsize=1)
def _simplified_chinese_converter() -> OpenCC:
    return OpenCC("t2s")


def simplify_chinese(text: str) -> str:
    return _simplified_chinese_converter().convert(text)
