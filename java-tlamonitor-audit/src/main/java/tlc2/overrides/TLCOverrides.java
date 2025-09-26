package tlc2.overrides;

public class TLCOverrides implements ITLCOverrides {
    @SuppressWarnings("rawtypes")
    @Override
    public Class[] get() {
        return new Class[]{ NatsOps.class };
    }
}
