async def ensure_stream(js, JS_STREAM, WANTED_SUBJECTS):
    """
    Ensure the JetStream stream exists and captures the subjects we want.
    If it exists with different subjects, we update it. If missing, we create it.
    """
    try:
        # network call
        info = await js.stream_info(JS_STREAM)  # exists?
        if isinstance(WANTED_SUBJECTS, str):
            WANTED_SUBJECTS = [WANTED_SUBJECTS]
        current = set(info.config.subjects)
        wanted = set(WANTED_SUBJECTS)
        if current != wanted:
            await js.update_stream(name=JS_STREAM, subjects=WANTED_SUBJECTS)
            print(f"Updated stream '{JS_STREAM}' subjects -> {WANTED_SUBJECTS}")
        else:
            print(f"Stream '{JS_STREAM}' is configured ok")
    except JetStreamNotFoundError:
        # not found -> create it
        await js.add_stream(
            name=JS_STREAM,
            subjects=WANTED_SUBJECTS,
            storage="file",
            max_msgs=0,
            max_bytes=0,
            # max_age=24*60*60,  # uncomment to limit retention by time (e.g. 24h)
        )
        print(f"Created stream '{JS_STREAM}' with subjects {WANTED_SUBJECTS}")