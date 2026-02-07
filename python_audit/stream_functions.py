import logging
from datetime import timedelta
from typing import Sequence

from nats.js.errors import NotFoundError as JetStreamNotFoundError
from nats.js.api import StreamConfig, AckPolicy, ConsumerConfig, DeliverPolicy


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
        max_age=max_age.total_seconds()
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

async def ensure_consumer(
        js,
        *,
        stream_name: str,
        durable_name: str,
        filter_subject: str,
        deliver_policy: DeliverPolicy = DeliverPolicy.ALL,
        ack_wait_s: int = 30,
        max_deliver: int = 5,
    ) -> None:
    """
    Ensure a durable consumer exists on stream_name with explicit config.
    We refer to consumer by its DURABLE name
    """

    cfg = ConsumerConfig(
        durable_name=durable_name,
        filter_subject=filter_subject,
        ack_policy=AckPolicy.EXPLICIT,
        deliver_policy=deliver_policy,
        ack_wait=ack_wait_s,
        max_deliver=max_deliver,
    )

    try:
        await js.add_consumer(stream_name, cfg)
        log.info("Created consumer durable=%s stream=%s filter=%s", durable_name, stream_name, filter_subject)
    except Exception:
        info = await js.consumer_info(stream_name, durable_name)
        log.info(
            "Using existing consumer durable=%s stream=%s filter=%s deliver=%s ack_wait=%s max_deliver=%s",
            durable_name,
            stream_name,
            info.config.filter_subject,
            info.config.deliver_policy,
            info.config.ack_wait,
            info.config.max_deliver,
        )
