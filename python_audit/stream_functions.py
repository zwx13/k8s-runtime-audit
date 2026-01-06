import logging


log = logging.getLogger(__name__)


def normalize_subjects(subjects):
    if isinstance(subjects, str):
        return [subjects]

async def ensure_stream(js, *, stream_name: str, subjects: list[str]) -> None:
    """
    Ensure the JetStream stream exists and captures the subjects we want.
    If it exists with different subjects, we update it. If missing, we create it.
    Subject won't show unless it has at least one message.
    """
    normalized_subjects = normalize_subjects(subjects)
    try:
        # network call
        info = await js.stream_info(stream_name)  # exists?

        configured = set(info.config.subjects)
        desired = set(normalized_subjects)

        if configured != desired:
            await js.update_stream(name=stream_name, subjects=normalized_subjects)
            log.info("Updated stream %r subjects -> %s", stream_name, subjects)
        else:
            log.info("Stream %r already configured", stream_name)

    except JetStreamNotFoundError:
        await js.add_stream(
            name=stream_name,
            subjects=normalized_subjects,
            storage="file",
            # max_msgs=0,
            # max_bytes=0,
            # max_age=24*60*60,  # uncomment to limit retention by time (e.g. 24h)
        )
        log.info("Created stream %r with subjects=%s", stream_name, subjects)