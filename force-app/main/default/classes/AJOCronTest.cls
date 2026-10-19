/**
 * The evaluator is verified against the org itself, not against a specification.
 *
 * Every row below is a real CronTrigger captured from the source production org: the
 * expression, the platform's own PreviousFireTime, and the platform's own
 * NextFireTime. Feeding the previous fire time back in must reproduce the next
 * one exactly. 57 distinct live expressions, covering every construct the
 * production org actually uses. Paused triggers are excluded: the platform
 * leaves a stale NextFireTime on them, so they are not a parity signal.
 */
@IsTest
private class AJOCronTest {

    private static final String TZ = 'Asia/Kolkata';

    /** expression, previousFireTime (UTC), nextFireTime (UTC), source job name */
    private static final List<String[]> PARITY = new List<String[]>{
            new String[]{ '0 0 10 ? * MON,WED,FRI', '2026-08-28 04:30:00', '2026-08-31 04:30:00', 'Asset Preservation Scheduler' },
            new String[]{ '0 0 22 1/1 * ?', '2026-08-27 16:30:00', '2026-08-28 16:30:00', 'AssetContractBatchScheduler' },
            new String[]{ '0 0 7 * * ?', '2026-08-28 01:30:00', '2026-08-29 01:30:00', 'AssetScoreScheduler 1' },
            new String[]{ '0 0 0 ? JAN,FEB,MAR,APR,MAY,JUN,JUL,AUG,SEP,OCT,NOV,DEC SUN,MON,TUE,WED,THU,FRI,SAT *', '2026-08-27 18:30:00', '2026-08-28 18:30:00', 'Auto Dispatch' },
            new String[]{ '0 30 0/1 1/1 * ? *', '2026-08-28 04:00:00', '2026-08-28 05:00:00', 'AUTORDER001' },
            new String[]{ '0 0 0/1 1/1 * ? *', '2026-08-28 04:30:00', '2026-08-28 05:30:00', 'AUTORDER002' },
            new String[]{ '0 02 * * * ?', '2026-08-28 04:32:00', '2026-08-28 05:32:00', 'BISCHEDULER001' },
            new String[]{ '0 24 * * * ?', '2026-08-28 03:54:00', '2026-08-28 04:54:00', 'BISCHEDULER002' },
            new String[]{ '0 44 * * * ?', '2026-08-28 04:14:00', '2026-08-28 05:14:00', 'BISCHEDULER008' },
            new String[]{ '0 04 * * * ?', '2026-08-28 04:34:00', '2026-08-28 05:34:00', 'BISCHEDULER010' },
            new String[]{ '0 0 0 * * ?', '2026-08-27 18:30:03', '2026-08-28 18:30:00', 'CCC_ScheduleDPR' },
            new String[]{ '0 0 * * * ?', '2026-08-28 04:30:00', '2026-08-28 05:30:00', 'Create Service Report For Engineer - 2' },
            new String[]{ '0 20 0 * * ?', '2026-08-27 18:50:00', '2026-08-28 18:50:00', 'CRFClose' },
            new String[]{ '0 0 20 */15 * ? *', '2026-08-16 14:30:00', '2026-08-31 14:30:00', 'Deactivate inactive users' },
            new String[]{ '0 00 23 05 * ?', '2026-08-05 17:30:00', '2026-09-05 17:30:00', 'DealerScoreCardScheduable' },
            new String[]{ '0 30 5 1/1 * ? *', '2026-08-28 00:00:00', '2026-08-29 00:00:00', 'DMS Task Email Scheduler' },
            new String[]{ '0 0 0 22 6,9 ? *', '2026-06-21 18:30:01', '2026-09-21 18:30:00', 'DSCFillingDataBatchScheduler Job 1' },
            new String[]{ '0 0 0 23 12,3 ? *', '2026-03-22 18:30:00', '2026-12-22 18:30:00', 'DSCFillingDataBatchScheduler Job 2' },
            new String[]{ '0 0 3 1 1,4,7,10 ? *', '2026-06-30 21:30:00', '2026-09-30 21:30:00', 'DSCQuarterlyRecordCreation' },
            new String[]{ '0 0 0 30 6,9 ? *', '2026-06-29 18:30:00', '2026-09-29 18:30:00', 'DSCUploadingOverdueScheduler Job 1' },
            new String[]{ '0 0 0 31 12,3 ? *', '2026-03-30 18:30:00', '2026-12-30 18:30:00', 'DSCUploadingOverdueScheduler Job 2' },
            new String[]{ '0 34 * * * ?', '2026-08-28 04:04:00', '2026-08-28 05:04:00', 'EMAILSCHEDULER004' },
            new String[]{ '0 54 * * * ?', '2026-08-28 04:24:00', '2026-08-28 05:24:00', 'EMAILSCHEDULER006' },
            new String[]{ '0 27 * * * ?', '2026-08-28 03:57:00', '2026-08-28 04:57:00', 'GIEA Schedular - Hourly - 1' },
            new String[]{ '0 28 * * * ?', '2026-08-28 03:58:00', '2026-08-28 04:58:00', 'GIEA Schedular - Hourly - 4' },
            new String[]{ '0 18 * * * ?', '2026-08-28 03:48:00', '2026-08-28 04:48:00', 'GIEA Schedular - Hourly - 5' },
            new String[]{ '0 17 * * * ?', '2026-08-28 03:47:00', '2026-08-28 04:47:00', 'GIEABIInterfaceQueueableScheduler' },
            new String[]{ '0 0 11 ? * 1,2,3,4,5,6,7', '2026-08-27 05:30:00', '2026-08-28 05:30:00', 'GOEM Credit Note Summary Approval Aler' },
            new String[]{ '0 0 11 ? * 2,4,6', '2026-08-26 05:30:00', '2026-08-28 05:30:00', 'GOEM Credit Note Summary Escalation Al' },
            new String[]{ '0 0 11 5,15,25 * ?', '2026-08-25 05:30:00', '2026-09-05 05:30:00', 'GOEM Inquiry Monthly Cancelled' },
            new String[]{ '0 0 10 30 * ?', '2026-07-30 04:30:01', '2026-08-30 04:30:00', 'GOEM Monthly Approved Credit Note' },
            new String[]{ '0 0 8 1 */1 ?', '2026-08-01 02:30:00', '2026-09-01 02:30:00', 'GOEM Monthly Approved SSA' },
            new String[]{ '0 0 14,21 * * ?', '2026-08-27 15:30:00', '2026-08-28 08:30:00', 'GOEM Ordered Booking Batch' },
            new String[]{ '0 0 18 ? * 1,2,3,4,5,6,7', '2026-08-27 12:30:00', '2026-08-28 12:30:00', 'GOEM Secondary Shipment Schedule Batch' },
            new String[]{ '0 0 14 ? * 2', '2026-08-24 08:30:01', '2026-08-31 08:30:00', 'GOEM SSA Approval Alert' },
            new String[]{ '0 0 14 3,6,9,12,15,18,21,24,27,30 * ?', '2026-08-27 08:30:00', '2026-08-30 08:30:00', 'GOEM SSA Reminder To Approver' },
            new String[]{ '0 0 2 * * ?', '2026-08-27 20:30:00', '2026-08-28 20:30:00', 'LKVA_UpdateItemFlag' },
            new String[]{ '0 0 0/1 ? JAN,FEB,MAR,APR,MAY,JUN,JUL,AUG,SEP,OCT,NOV,DEC SUN,MON,TUE,WED,THU,FRI,SAT *', '2026-08-28 04:30:00', '2026-08-28 05:30:00', 'Optimization#FSL#' },
            new String[]{ '0 45 * * * ?', '2026-08-28 04:15:00', '2026-08-28 05:15:00', 'PMGEN - Hourly' },
            new String[]{ '0 0 4 1/1 * ? *', '2026-08-27 22:30:00', '2026-08-28 22:30:00', 'PMTASKQUEUE001' },
            new String[]{ '0 38 * * * ?', '2026-08-28 04:08:00', '2026-08-28 05:08:00', 'PMTASKQUEUE002' },
            new String[]{ '0 30 * * * ?', '2026-08-28 04:00:00', '2026-08-28 05:00:00', 'PMTASKSCHEDULER - Hourly' },
            new String[]{ '0 0 9 1/1 * ? *', '2026-08-28 03:30:03', '2026-08-29 03:30:00', 'Price Book External Data - Daily' },
            new String[]{ '0 15 0 1/1 * ? *', '2026-08-27 18:45:00', '2026-08-28 18:45:00', 'PROCESSAUTORDER' },
            new String[]{ '0 47 * * * ?', '2026-08-28 04:17:00', '2026-08-28 05:17:00', 'RenewContract-Hourly' },
            new String[]{ '0 00 * * * ?', '2026-08-28 04:30:00', '2026-08-28 05:30:00', 'SaleInvoicePostingScheduler Job 1' },
            new String[]{ '0 20 * * * ?', '2026-08-28 03:50:00', '2026-08-28 04:50:00', 'SaleInvoicePostingScheduler Job 3' },
            new String[]{ '0 40 * * * ?', '2026-08-28 04:10:00', '2026-08-28 05:10:00', 'SaleInvoicePostingScheduler Job 4' },
            new String[]{ '0 0 5 ? * 1,2,3,4,5,6,7', '2026-08-27 23:30:00', '2026-08-28 23:30:00', 'ScheduleAMCBatchClone' },
            new String[]{ '0 15 23 * * ?', '2026-08-27 17:45:00', '2026-08-28 17:45:00', 'Scheduled Job 11:15 PM' },
            new String[]{ '0 30 19 * * ?', '2026-08-27 14:00:00', '2026-08-28 14:00:00', 'SendInvoiceToNpsBatch Job 7:30 PM' },
            new String[]{ '0 0 8 ? * 1,2,3,4,5,6,7', '2026-08-28 02:30:01', '2026-08-29 02:30:00', 'Service Lead B Check - Daily' },
            new String[]{ '0 0 21 * * ?', '2026-08-27 15:30:00', '2026-08-28 15:30:00', 'ServiceAutoAssignmentProcessScheduler' },
            new String[]{ '0 0 0 1 * ?', '2026-07-31 18:30:00', '2026-08-31 18:30:00', 'Timesheet batch' },
            new String[]{ '0 15 * * * ?', '2026-08-28 03:45:00', '2026-08-28 04:45:00', 'VCL Invoices 01' },
            new String[]{ '0 0 23 * * ?', '2026-08-27 17:30:01', '2026-08-28 17:30:00', 'WCC_Interface' },
            new String[]{ '0 0 22 * * ?', '2026-08-27 16:30:01', '2026-08-28 16:30:00', 'WCC_JOB' }
    };

    @IsTest
    static void reproducesEveryProductionSchedule() {
        List<String> failures = new List<String>();

        for (String[] row : PARITY) {
            String expr = row[0];
            Datetime prev = Datetime.valueOfGmt(row[1]);
            Datetime expected = Datetime.valueOfGmt(row[2]);

            Datetime actual;
            try {
                actual = AJOCron.next(expr, prev, TZ);
            } catch (Exception e) {
                failures.add(row[3] + ' | ' + expr + ' | threw ' + e.getMessage());
                continue;
            }
            if (actual != expected) {
                failures.add(row[3] + ' | ' + expr
                    + ' | from ' + row[1]
                    + ' | expected ' + row[2]
                    + ' | got ' + (actual == null ? 'null' : actual.formatGmt('yyyy-MM-dd HH:mm:ss')));
            }
        }

        System.assertEquals(
            new List<String>(), failures,
            failures.size() + ' of ' + PARITY.size()
            + ' production schedules did not reproduce.');
    }

    @IsTest
    static void handlesTheAwkwardConstructs() {
        // Every-15-days stepping from day 1, as used by "Deactivate inactive users".
        Datetime startFrom = Datetime.valueOfGmt('2026-08-16 14:30:00');
        Datetime next = AJOCron.next('0 0 20 */15 * ? *', startFrom, TZ);
        System.assertEquals(Datetime.valueOfGmt('2026-08-31 14:30:00'), next,
            'DOM step should walk 1, 16, 31.');

        // Named months and named weekdays together, as used by "Auto Dispatch".
        Datetime d2 = AJOCron.next(
            '0 0 0/1 ? JAN,FEB,MAR,APR,MAY,JUN,JUL,AUG,SEP,OCT,NOV,DEC SUN,MON,TUE,WED,THU,FRI,SAT *',
            Datetime.valueOfGmt('2026-08-28 04:30:00'), TZ);
        System.assertEquals(Datetime.valueOfGmt('2026-08-28 05:30:00'), d2,
            'Hourly with every named month and weekday.');

        // Quarterly on the first of the month.
        Datetime d3 = AJOCron.next('0 0 3 1 1,4,7,10 ? *',
            Datetime.valueOfGmt('2026-06-30 21:30:00'), TZ);
        System.assertEquals(Datetime.valueOfGmt('2026-09-30 21:30:00'), d3,
            'Quarterly at 03:00 IST on the 1st.');

        // A long explicit day-of-month list.
        Datetime d4 = AJOCron.next('0 0 14 3,6,9,12,15,18,21,24,27,30 * ?',
            Datetime.valueOfGmt('2026-08-27 08:30:00'), TZ);
        System.assertEquals(Datetime.valueOfGmt('2026-08-30 08:30:00'), d4,
            'Every third day of the month at 14:00 IST.');
    }

    @IsTest
    static void evaluatesInTheConfiguredZoneNotTheUsers() {
        Datetime startFrom = Datetime.valueOfGmt('2026-08-28 00:00:00');
        Datetime ist = AJOCron.next('0 0 9 * * ?', startFrom, 'Asia/Kolkata');
        Datetime utc = AJOCron.next('0 0 9 * * ?', startFrom, 'GMT');
        System.assertNotEquals(ist, utc,
            'The same expression in two zones must resolve to different instants.');
        System.assertEquals(Datetime.valueOfGmt('2026-08-28 03:30:00'), ist,
            '09:00 Asia/Kolkata is 03:30 UTC.');
        System.assertEquals(Datetime.valueOfGmt('2026-08-28 09:00:00'), utc,
            '09:00 GMT is 09:00 UTC.');
    }

    @IsTest
    static void producesASeriesOfFireTimes() {
        List<Datetime> five = AJOCron.nextN('0 0 * * * ?',
            Datetime.valueOfGmt('2026-08-28 00:00:00'), TZ, 5);
        System.assertEquals(5, five.size(), 'Should return five occurrences.');
        for (Integer i = 1; i < five.size(); i++) {
            System.assert(five[i] > five[i - 1], 'The series must be strictly increasing.');
        }
    }

    @IsTest
    static void rejectsWhatItCannotEvaluate() {
        assertThrows('0 0 12 L * ?',        'last-day-of-month');
        assertThrows('0 0 12 ? * 6#3',      'nth weekday');
        assertThrows('0 0 12 15W * ?',      'nearest weekday');
        assertThrows('not a cron',          'nonsense');
        assertThrows('0 0 12 * *',          'too few fields');
        assertThrows('0 99 12 * * ?',       'minute out of range');
    }

    private static void assertThrows(String expr, String why) {
        try {
            AJOCron.next(expr, Datetime.now(), TZ);
            System.assert(false, 'Expected a CronException for ' + why + ': ' + expr);
        } catch (AJOCron.CronException e) {
            // expected
        }
    }

    @IsTest
    static void describesSchedulesInPlainEnglish() {
        System.assertEquals('Every hour at :17', AJOCron.describeSchedule('0 17 * * * ?'));
        System.assertEquals('Daily at 09:00',    AJOCron.describeSchedule('0 0 9 * * ?'));
        System.assertEquals('Invalid schedule',  AJOCron.describeSchedule('rubbish'));
        System.assert(AJOCron.describeSchedule('0 0 10 ? * MON,WED,FRI').contains('Mon'),
            'Weekday schedules should name their days.');
    }

    /**
     * A multi-minute schedule used to describe itself by the *count* of its
     * minutes: '0 0,30 * * * ?' read as "Every hour, at 2 minutes past", and
     * '0 0-30 * * * ?' claimed minute 31. This is the string the Jobs table
     * shows in its Runs column, so it was wrong in the one place people read it.
     */
    @IsTest
    static void describesEveryHalfHourAsACadenceNotACount() {
        for (String expr : new List<String>{
                '0 0,30 * * * ?', '0 0/30 * * * ?', '0 */30 * * * ?' }) {
            System.assertEquals('Every 30 minutes', AJOCron.describeSchedule(expr),
                'Wrong description for ' + expr);
        }
        System.assertEquals('Every 15 minutes',
            AJOCron.describeSchedule('0 0,15,30,45 * * * ?'));
        System.assertEquals('Every 10 minutes', AJOCron.describeSchedule('0 0/10 * * * ?'));

        // An offset cadence keeps its offset rather than pretending to be on the hour.
        System.assertEquals('Every 30 minutes from :05',
            AJOCron.describeSchedule('0 5,35 * * * ?'));

        // A contiguous run of minutes is a range, not a cadence.
        System.assertEquals('Every minute from :00 to :30',
            AJOCron.describeSchedule('0 0-30 * * * ?'));

        // Minutes that form no cadence at all are simply listed.
        System.assertEquals('Every hour at :00, :05, :30',
            AJOCron.describeSchedule('0 0,5,30 * * * ?'));

        System.assertEquals('Every minute', AJOCron.describeSchedule('0 * * * * ?'));
    }

    @IsTest
    static void describesAllTheTimesInAFixedHour() {
        // The second minute used to be dropped: this read as "Daily at 01:00".
        System.assertEquals('Daily at 01:00 and 01:30',
            AJOCron.describeSchedule('0 0,30 1 * * ?'));
        System.assertEquals('Daily at 01:30', AJOCron.describeSchedule('0 30 1 * * ?'));
    }
}