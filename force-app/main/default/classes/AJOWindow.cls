/**
 * The activation window: the dates between which a job is allowed to run.
 *
 * This is what lets a limited piece of data processing be scheduled for ten days
 * and then stop on its own, instead of relying on somebody remembering to switch
 * it off. A blank End Date means the job runs for as long as it stays enabled.
 *
 * The same rule is expressed three times and the three must stay in step:
 *
 *   1. AJOJob__c.AJO_IsActive__c, a formula field, so record pages, list views
 *      and reports say the same thing the dispatcher does.
 *   2. SOQL_FILTER, so the heartbeat's selective query never even loads a job
 *      that could not run.
 *   3. isActive(), for the paths that already hold the record in memory.
 *
 * All three evaluate at day granularity: End Date is inclusive, so a job whose
 * window ends today still runs today. The day boundary is the one the automation
 * user sees — Date.today() in Apex, TODAY in SOQL and TODAY() in the formula all
 * resolve in that same time zone, which is what keeps the three answers identical.
 * Cron minutes remain evaluated in the job's own time zone; only the window is
 * day-granular.
 */
public with sharing class AJOWindow {

    /**
     * Appendable to any WHERE clause over AJOJob__c. Deliberately built from real
     * field comparisons rather than the formula field: date fields are indexed and
     * a formula field is not, and the heartbeat query has to stay selective.
     */
    public static final String SOQL_FILTER =
        '(AJO_Enabled__c = true '
        + 'AND (AJO_StartDate__c = null OR AJO_StartDate__c <= TODAY) '
        + 'AND (AJO_EndDate__c = null OR AJO_EndDate__c >= TODAY))';

    /** True when the job may run right now. The Apex twin of AJO_IsActive__c. */
    public static Boolean isActive(AJOJob__c job) {
        if (job.AJO_Enabled__c != true) { return false; }
        Date today = Date.today();
        if (job.AJO_StartDate__c != null && job.AJO_StartDate__c > today) { return false; }
        if (job.AJO_EndDate__c   != null && job.AJO_EndDate__c   < today) { return false; }
        return true;
    }

    /** The window has closed: this job will never be due again. */
    public static Boolean hasExpired(AJOJob__c job) {
        return job.AJO_EndDate__c != null && job.AJO_EndDate__c < Date.today();
    }

    /** The window has not opened yet. */
    public static Boolean hasNotStarted(AJOJob__c job) {
        return job.AJO_StartDate__c != null && job.AJO_StartDate__c > Date.today();
    }

    /**
     * The instant the window opens, or null when there is no Start Date. Used to
     * push a not-yet-started job's NextRunAt forward to its first permitted
     * occurrence, so the console never advertises a run the job cannot take.
     */
    public static Datetime opensAt(AJOJob__c job) {
        return job.AJO_StartDate__c == null
               ? null
               : Datetime.newInstance(job.AJO_StartDate__c, Time.newInstance(0, 0, 0, 0));
    }

    /**
     * True when a computed fire time falls past the end of the window. Used when
     * advancing NextRunAt, so the last occurrence inside the window is genuinely
     * the last one scheduled rather than one the dispatcher keeps rejecting.
     */
    public static Boolean isBeyondWindow(AJOJob__c job, Datetime fireTime) {
        if (fireTime == null || job.AJO_EndDate__c == null) { return false; }
        return fireTime.date() > job.AJO_EndDate__c;
    }

    /** Why the job is or is not active. Mirrors AJO_WindowStatus__c. */
    public static String describe(AJOJob__c job) {
        if (job.AJO_Enabled__c != true)  { return 'Paused'; }
        if (hasNotStarted(job)) { return 'Starts ' + String.valueOf(job.AJO_StartDate__c); }
        if (hasExpired(job))    { return 'Expired ' + String.valueOf(job.AJO_EndDate__c); }
        if (job.AJO_EndDate__c == null) { return 'Active, no end date'; }
        return 'Active, ' + daysRemaining(job) + ' day(s) left';
    }

    /** Days left in the window including today. Null when there is no end date. */
    public static Integer daysRemaining(AJOJob__c job) {
        if (job.AJO_EndDate__c == null) { return null; }
        Integer d = Date.today().daysBetween(job.AJO_EndDate__c) + 1;
        return d < 0 ? 0 : d;
    }

    /**
     * Rejects a window that could never make a job active. Called before save so
     * the mistake surfaces to whoever made it, not as a job that quietly never runs.
     */
    public static void validate(Date startDate, Date endDate) {
        if (startDate != null && endDate != null && endDate < startDate) {
            throw new WindowException(
                'End Date (' + endDate + ') cannot be earlier than Start Date ('
                + startDate + '). Leave End Date blank to run indefinitely.');
        }
    }

    public class WindowException extends Exception {}
}
