/** Reads AJOSetting__c with defaults, so a missing setting never breaks a run. */
public with sharing class AJOConfig {

    public static final Integer DEFAULT_HEARTBEAT_MINUTES = 10;
    public static final Integer DEFAULT_MAX_BATCHES       = 5;
    public static final Integer PLATFORM_DELAY_CAP        = 10;
    public static final Integer SLOT_LIMIT                = 100;

    private static AJOSetting__c cached;

    public static AJOSetting__c get() {
        if (cached == null) {
            cached = AJOSetting__c.getOrgDefaults();
            if (cached == null) { cached = new AJOSetting__c(); }
        }
        return cached;
    }

    @TestVisible
    private static void applyOverride(AJOSetting__c s) { cached = s; }

    public static Boolean killSwitch() {
        return get().AJO_KillSwitch__c == true;
    }

    public static Integer heartbeatMinutes() {
        Decimal v = get().AJO_HeartbeatMinutes__c;
        return (v == null || v <= 0) ? DEFAULT_HEARTBEAT_MINUTES : v.intValue();
    }

    public static Integer maxConcurrentBatches() {
        Decimal v = get().AJO_MaxConcurrentBatches__c;
        return (v == null || v <= 0) ? DEFAULT_MAX_BATCHES : v.intValue();
    }

    public static Boolean deferralEnabled() {
        return get().AJO_EnableDeferral__c != false;
    }

    public static Integer retentionSuccessDays() {
        Decimal v = get().AJO_RetentionDaysSuccess__c;
        return (v == null || v <= 0) ? 14 : v.intValue();
    }

    public static Integer retentionFailureDays() {
        Decimal v = get().AJO_RetentionDaysFailure__c;
        return (v == null || v <= 0) ? 90 : v.intValue();
    }

    public static String defaultTimeZone() {
        String v = get().AJO_DefaultTimeZone__c;
        return String.isBlank(v) ? AJOCron.DEFAULT_TZ : v;
    }

    public static String digestEmail() { return get().AJO_DigestEmail__c; }
}