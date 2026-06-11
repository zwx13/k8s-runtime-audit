 /**
 * This file is necessary in order to load our own operators into TLC.
 * Contains some debugging messages.
 */
package tlc2.overrides;

public class TLCOverrides implements ITLCOverrides {
    
    static {
        System.err.println(">>>>>> [TLCOverrides] class loaded at " + java.time.Instant.now());
    }
    
    @SuppressWarnings("rawtypes")
    @Override
    public Class[] get() {
        System.err.println(">>>>>> [TLCOverrides] get() called at " + java.time.Instant.now());
        return new Class[]{ NatsOps.class };
    }
}
