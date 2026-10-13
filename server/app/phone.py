import re

_NON_DIGIT = re.compile(r"[^0-9]")


def normalize(value: str) -> str:
    """Mirrors lib/core/utils/phone_normalizer.dart PhoneNormalizer.normalize."""
    digits = _NON_DIGIT.sub("", value)
    if digits.startswith("998"):
        return digits
    if len(digits) == 9:
        return f"998{digits}"
    return digits


def is_valid_uzbek_phone(value: str) -> bool:
    return re.fullmatch(r"998\d{9}", normalize(value)) is not None


def phone_like_wildcard(term: str) -> str | None:
    """SQL LIKE wildcard for a normalized-phone search term, or None (-> SQL
    NULL, which never matches anything) when the term has no digits at all --
    otherwise 'phone_normalized LIKE %%' would match *every* phone number
    instead of none."""
    normalized = normalize(term)
    return f"%{normalized}%" if normalized else None
