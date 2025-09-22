package tla.monitor.audit.operators;

import tlc2.overrides.ITLCOverrides;

public class TLCOperators implements ITLCOverrides {
    @SuppressWarnings("rawtypes")
    @Override
    public Class[] get() {
        return new Class[]{ NatsOps.class };
    }
}
