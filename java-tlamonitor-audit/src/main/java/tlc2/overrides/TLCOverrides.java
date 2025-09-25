package tlc2.overrides;

import tlc2.overrides.ITLCOverrides;

public class TLCOverrides implements ITLCOverrides {
    @SuppressWarnings("rawtypes")
    @Override
    public Class[] get() {
        return new Class[]{ NatsOps.class };
    }
}
