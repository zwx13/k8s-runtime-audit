import logging
from datetime import timedelta
from typing import Sequence

from nats.js.errors import NotFoundError as JetStreamNotFoundError
from nats.js.api import StreamConfig


log = logging.getLogger(__name__)


def normalize_subjects(subjects):
    """Make subjects always be a list of subject strings"""
    if isinstance(subjects, str):
        return [subjects]
    else:
        return list(subjects)

async def ensure_stream(
    js,
    *,
    stream_name: str,
    subjects: str | Sequence[str],
    max_age: timedelta = timedelta(days=7)) -> None:
    """
    Confirm a JetStream stream exists with the desired subjects and retention policy.

    - If missing: create it.
    - If present but config differs (subjects/max_age/storage): update it.

    Note: a subject may not appear in stream info until at least one message is stored.
    """
    normalized_subjects = normalize_subjects(subjects)

    desired_cfg = StreamConfig(
        name=stream_name,
        subjects=normalized_subjects,
        storage="file",
        max_age=max_age
    )
    try:
        info = await js.stream_info(stream_name)

        if (
            set(info.config.subjects) != set(normalized_subjects)
            or info.config.max_age != desired_cfg.max_age
           ):

            await js.update_stream(desired_cfg)
            log.info("Updated stream=%s subjects=%s max_age=%s",
                                 stream_name, normalized_subjects, max_age)
        else:
            log.info("Stream %r already configured with subjects=%s max_age=%s",
                                 stream_name, normalized_subjects, max_age)

    except JetStreamNotFoundError:
        await js.add_stream(desired_cfg)
        log.info("Created stream %r with subjects=%s max_age=%s",
                                  stream_name, normalized_subjects, max_age)
