/**
 * Arms and disarms the permanent slots.
 * Six heartbeats plus one supervisor — seven registrations, whatever the job count.
 */
public with sharing class AJOInstaller {

    public static final String HEARTBEAT_PREFIX = 'AJO Heartbeat ';
    public static final String SUPERVISOR_NAME    = 'AJO Supervisor';

    public static List<Integer> slots() {
        List<Integer> out = new List<Integer>();
        Integer step = AJOConfig.heartbeatMinutes();
        for (Integer m = 0; m < 60; m += step) { out.add(m); }
        return out;
    }

    public static String heartbeatName(Integer minute) {
        return HEARTBEAT_PREFIX + (minute < 10 ? '0' : '') + minute;
    }

    /** Schedules every heartbeat plus the supervisor. Idempotent. */
    public static List<String> arm() {
        List<String> armed = new List<String>();
        Map<String, CronTrigger> existing = scheduledByName();

        for (Integer m : slots()) {
            String nm = heartbeatName(m);
            if (existing.containsKey(nm)) { continue; }
            String cron = '0 ' + m + ' * * * ?';
            System.schedule(nm, cron, new AJODispatcher(m));
            armed.add(nm);
        }
        if (!existing.containsKey(SUPERVISOR_NAME)) {
            System.schedule(SUPERVISOR_NAME, '0 5 2 * * ?', new AJOSupervisor());
            armed.add(SUPERVISOR_NAME);
        }
        return armed;
    }

    /** Re-creates only what has gone missing. Called daily by the supervisor. */
    public static Integer rearmMissing() {
        try { return arm().size(); } catch (Exception e) { return -1; }
    }

    public static List<String> disarm() {
        List<String> removed = new List<String>();
        for (CronTrigger ct : ownTriggers()) {
            System.abortJob(ct.Id);
            removed.add(ct.CronJobDetail.Name);
        }
        return removed;
    }

    public static List<CronTrigger> ownTriggers() {
        String pattern = HEARTBEAT_PREFIX + '%';
        String supervisor = SUPERVISOR_NAME;
        return [
            SELECT Id, CronExpression, State, NextFireTime, PreviousFireTime,
                   TimesTriggered, CronJobDetail.Name
            FROM   CronTrigger
            WHERE  CronJobDetail.JobType = '7'
              AND  (CronJobDetail.Name LIKE :pattern
                    OR CronJobDetail.Name = :supervisor)
            ORDER BY CronJobDetail.Name
        ];
    }

    private static Map<String, CronTrigger> scheduledByName() {
        Map<String, CronTrigger> m = new Map<String, CronTrigger>();
        for (CronTrigger ct : ownTriggers()) {
            m.put(ct.CronJobDetail.Name, ct);
        }
        return m;
    }

    /** The number this whole project exists to reduce. */
    public static Integer scheduledApexSlotsUsed() {
        return [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.JobType = '7'];
    }

    /** Seeds sensible defaults so a fresh org works without Setup clicks. */
    public static AJOSetting__c ensureSettings() {
        AJOSetting__c s = AJOSetting__c.getOrgDefaults();
        Boolean isNew = (s == null || s.Id == null);
        if (s == null) { s = new AJOSetting__c(); }
        if (s.AJO_HeartbeatMinutes__c == null)      { s.AJO_HeartbeatMinutes__c = 10; }
        if (s.AJO_MaxConcurrentBatches__c == null)  { s.AJO_MaxConcurrentBatches__c = 5; }
        if (s.AJO_RetentionDaysSuccess__c == null)  { s.AJO_RetentionDaysSuccess__c = 14; }
        if (s.AJO_RetentionDaysFailure__c == null)  { s.AJO_RetentionDaysFailure__c = 90; }
        if (String.isBlank(s.AJO_DefaultTimeZone__c)) { s.AJO_DefaultTimeZone__c = AJOCron.DEFAULT_TZ; }
        if (s.AJO_EnableDeferral__c == null)        { s.AJO_EnableDeferral__c = true; }
        if (s.AJO_KillSwitch__c == null)            { s.AJO_KillSwitch__c = false; }
        if (isNew) { insert s; } else { update s; }
        return s;
    }
}