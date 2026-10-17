from datetime import date, datetime, time
from uuid import UUID

from pydantic import BaseModel


class LoginRequest(BaseModel):
    phone: str
    password: str


class LoginResponse(BaseModel):
    token: str
    user_id: int
    role: str
    full_name: str
    phone: str


class MeResponse(BaseModel):
    user_id: int
    phone: str
    full_name: str
    role: str


class CreateSubjectRequest(BaseModel):
    name: str


class Subject(BaseModel):
    id: int
    name: str
    created_at: datetime


class SubjectWithCount(BaseModel):
    id: int
    name: str
    group_count: int
    created_at: datetime


class CreateGroupRequest(BaseModel):
    subject_id: int
    name: str
    teacher_id: int | None = None
    # Older app builds still send a typed name instead of teacher_id -- it's
    # matched to (or becomes) a teacher record, see routes/groups.py.
    teacher_name: str | None = None
    fee_amount: int
    # How the group bills: 'fixed_day' (everyone on billing_day, 1-28) or
    # 'student_anniversary' (each student on their own start day).
    billing_mode: str = "fixed_day"
    billing_day: int | None = None
    # Prorate a first period that starts between billing days.
    prorate_first_period: bool = True
    level: str | None = None
    start_date: date | None = None
    # Older builds send due_day instead of billing_day.
    due_day: int | None = None
    capacity: int | None = None
    note: str | None = None


class UpdateGroupRequest(BaseModel):
    subject_id: int | None = None
    name: str | None = None
    teacher_id: int | None = None
    fee_amount: int | None = None
    billing_mode: str | None = None
    billing_day: int | None = None
    prorate_first_period: bool | None = None
    level: str | None = None
    start_date: date | None = None
    due_day: int | None = None
    # Null clears it (no seat limit).
    capacity: int | None = None
    note: str | None = None
    is_active: bool | None = None


class Group(BaseModel):
    id: int
    subject_id: int | None
    name: str
    teacher_id: int | None
    teacher_name: str | None
    fee_amount: int
    billing_mode: str
    billing_day: int | None
    prorate_first_period: bool
    level: str | None = None
    start_date: date | None = None
    # Pay rule of this group alone (null method = follows its teacher's);
    # shown to the owner and admin on the salary pages.
    salary_method: str | None = None
    salary_percent: float | None = None
    salary_fixed: int | None = None
    capacity: int | None = None
    is_active: bool
    note: str | None
    created_at: datetime


class GroupWithStudentCount(Group):
    student_count: int


class GroupListItem(GroupWithStudentCount):
    """A group plus its subject's name -- for the desktop Settings table,
    which lists every group across all subjects."""

    subject_name: str | None
    # The weekly lesson slots (defined further down).
    schedule: list["ScheduleSlot"] = []


class CreateTeacherRequest(BaseModel):
    full_name: str
    phone: str | None = None
    note: str | None = None


class UpdateTeacherRequest(BaseModel):
    full_name: str | None = None
    phone: str | None = None
    note: str | None = None
    is_active: bool | None = None


class Teacher(BaseModel):
    id: int
    full_name: str
    phone: str | None
    note: str | None
    is_active: bool
    created_at: datetime


class TeacherListItem(Teacher):
    group_count: int


class CreateStudentRequest(BaseModel):
    full_name: str
    phone: str
    telegram_username: str | None = None
    note: str | None = None
    parent_phone: str | None = None
    heard_from: str | None = None


class UpdateStudentRequest(BaseModel):
    full_name: str | None = None
    phone: str | None = None
    parent_phone: str | None = None
    address: str | None = None
    telegram_username: str | None = None
    note: str | None = None


class Student(BaseModel):
    id: int
    full_name: str
    phone: str
    telegram_username: str | None
    note: str | None
    parent_phone: str | None = None
    heard_from: str | None = None
    address: str | None = None
    created_at: datetime


class StudentListItem(BaseModel):
    """Student plus their total balance across every enrollment -- only the
    list endpoint joins/aggregates this, so it's a separate model from
    [Student] rather than a field every other student response has to
    fake with 0."""

    id: int
    full_name: str
    phone: str
    telegram_username: str | None
    note: str | None
    created_at: datetime
    balance: int
    # The groups they study in now, and how their last lessons went
    # (oldest first, at most ten) -- the table's attendance indicator.
    group_names: list[str] = []
    groups: list["StudentGroupRef"] = []
    attendance_recent: list[str] = []
    # How they did over those lessons (present or late, out of those they
    # were expected at); null until a lesson was marked.
    attendance_rate: float | None = None
    # The table's tabs -- one definition, here, for the app to count.
    is_new: bool = False
    is_debtor: bool = False
    is_at_risk: bool = False
    is_active: bool = False


class CreateEnrollmentRequest(BaseModel):
    student_id: int
    group_id: int
    joined_at: date


class Enrollment(BaseModel):
    id: int
    student_id: int
    group_id: int
    joined_at: date
    status: str
    ended_at: date | None
    created_at: datetime


class RosterEntry(BaseModel):
    """One row on a group's roster -- an enrollment joined with its
    student's identity, since the roster screen never needs to look up
    the student separately. balance > 0 means the student owes money."""

    enrollment_id: int
    student_id: int
    student_full_name: str
    student_phone: str
    joined_at: date
    status: str
    balance: int
    # When this enrollment's next charge falls due (today counts).
    next_due_date: date | None = None
    # Joined in the last two weeks: shown first on the roster, marked "Yangi".
    is_new: bool = False


class StudentEnrollment(BaseModel):
    """One row on a student's profile -- the mirror of RosterEntry, joined
    with the group's identity instead."""

    enrollment_id: int
    group_id: int
    group_name: str
    joined_at: date
    status: str
    balance: int
    next_due_date: date | None = None


class CreatePaymentRequest(BaseModel):
    amount: int
    note: str | None = None
    # 'cash' | 'card' | 'click_payme'. Builds from before methods were
    # recorded send none; those payments count as cash.
    method: str | None = None


class ReasonRequest(BaseModel):
    reason: str


class Transaction(BaseModel):
    id: int
    enrollment_id: int
    kind: str
    amount: int
    period_start: date | None
    due_date: date | None
    is_prorated: bool
    source: str
    note: str | None
    # Payments only; null for every payment recorded before methods existed.
    method: str | None = None
    occurred_at: datetime
    # 'active'/'cancelled' for charges, 'valid'/'cancelled' for payments.
    status: str = "active"
    receipt_no: str | None = None
    reason: str | None = None


class CreateInquiryRequest(BaseModel):
    full_name: str
    phone: str
    note: str | None = None
    subject_id: int | None = None
    trial_date: date | None = None


class UpdateInquiryRequest(BaseModel):
    note: str | None = None
    subject_id: int | None = None
    trial_date: date | None = None
    status: str | None = None


class Inquiry(BaseModel):
    id: int
    full_name: str
    phone: str
    note: str | None
    subject_id: int | None
    subject_name: str | None = None
    trial_date: date | None
    status: str
    converted_student_id: int | None
    created_at: datetime


class Debtor(BaseModel):
    """One enrollment that owes money -- per enrollment rather than per
    student, since a payment is always recorded against one enrollment.
    Withdrawn enrollments still appear: leaving doesn't clear a debt."""

    enrollment_id: int
    student_id: int
    student_full_name: str
    student_phone: str
    group_id: int
    group_name: str
    status: str
    balance: int
    oldest_unpaid_due: date | None
    # Days past the oldest unpaid charge's due date, and its bucket
    # ("0-7", "8-30", "30+").
    days_overdue: int = 0
    age_bucket: str | None = None


class TrialToday(BaseModel):
    # The lead's id (named for older app builds).
    inquiry_id: int
    full_name: str
    phone: str
    subject_name: str | None
    starts_at: datetime | None = None


class MonthlyRevenue(BaseModel):
    month: date
    amount: int


class RecentPayment(BaseModel):
    id: int
    enrollment_id: int
    student_full_name: str
    group_name: str
    amount: int
    occurred_at: datetime


class DashboardSummary(BaseModel):
    """Everything the desktop home screen shows, in one round trip. Dates and
    "this month" are the center's (see clock.py), not the server's."""

    today: date
    active_students: int
    new_students_this_month: int
    active_groups: int
    collected_this_month: int
    # What a full month brings in at current fees: the sum of every active
    # enrollment's group fee -- the yardstick for collected_this_month.
    monthly_plan: int
    total_debt: int
    debtor_count: int
    new_leads_this_week: int
    open_leads: int
    unanswered_leads: int
    due_today_count: int
    due_today_amount: int
    trials_today: list[TrialToday]
    revenue_by_month: list[MonthlyRevenue]
    recent_payments: list[RecentPayment]
    top_debtors: list[Debtor]


class CreateStudentWithEnrollmentRequest(BaseModel):
    """The "Yangi o'quvchi" dialog: a new student, added straight into a
    group, saved in one transaction (see routes/students.py)."""

    full_name: str
    phone: str
    group_id: int
    joined_at: date
    # 'prorated' (pay only for the days left in the current period) or
    # 'full' (a whole month's fee for it). Ignored when joined_at is the
    # group's due day itself -- both come to the full fee then.
    first_month: str | None = None
    discount_kind: str | None = None
    discount_value: int | None = None
    parent_phone: str | None = None
    heard_from: str | None = None
    note: str | None = None
    first_payment_amount: int | None = None
    first_payment_method: str | None = None


class StudentEnrolled(BaseModel):
    student: Student
    enrollment_id: int
    first_charge: int
    first_payment: int


class PhoneOwner(BaseModel):
    """Who already has a phone number -- the dialog's duplicate warning."""

    student_id: int
    full_name: str
    phone: str
    group_names: list[str]


class PhoneCheck(BaseModel):
    owner: PhoneOwner | None


class FirstChargePreview(BaseModel):
    """What the first charge would be, so the dialog can show both options
    before the user picks -- computed with the same code that charges."""

    monthly_fee: int
    discounted_fee: int
    period_start: date
    period_end: date
    days_left: int
    days_in_period: int
    prorated_amount: int
    full_amount: int
    # False when joining on the due day itself: prorated == full, no choice.
    is_mid_cycle: bool


# Admissions -----------------------------------------------------------------


class UserBrief(BaseModel):
    id: int
    full_name: str
    role: str


class CreateLeadRequest(BaseModel):
    full_name: str
    phone: str
    # Set by the offline outbox, so a lead made offline keeps one identity
    # however many times it's sent.
    client_id: UUID | None = None
    parent_phone: str | None = None
    subject_id: int | None = None
    source: str | None = None
    note: str | None = None
    # Defaults to whoever creates the lead.
    assigned_to: int | None = None
    preferred_trial_date: date | None = None
    # What the client asked for -- the days they can come (ISO weekdays, 1 =
    # Monday), the part of the day ('morning' | 'afternoon' | 'evening') and level.
    desired_weekdays: list[int] | None = None
    desired_time_of_day: str | None = None
    level: str | None = None
    # The group offered (Qabul's fast form); null = guruhsiz. Not an enrollment.
    group_id: int | None = None
    address: str | None = None
    # A free trial at one of that group's next lessons (its start time, as
    # listed by GET /groups/{id}/trial-dates); needs group_id.
    trial_starts_at: datetime | None = None
    remind: bool = False
    # 'reject': 409 if this phone already has an open lead for the course.
    # 'merge': add this inquiry to that lead's timeline instead and return
    # it -- what the offline outbox sends, since nobody is there to decide.
    on_duplicate: str = "reject"


class UpdateLeadRequest(BaseModel):
    # The version the operator was looking at; a stale one gets a 409.
    version: int
    full_name: str | None = None
    phone: str | None = None
    parent_phone: str | None = None
    subject_id: int | None = None
    source: str | None = None
    note: str | None = None
    assigned_to: int | None = None
    preferred_trial_date: date | None = None
    desired_weekdays: list[int] | None = None
    desired_time_of_day: str | None = None
    level: str | None = None


class ChangeLeadStageRequest(BaseModel):
    version: int
    stage: str
    reason: str | None = None
    # With 'follow_up_later': when to call back (creates the task).
    follow_up_at: datetime | None = None


class Lead(BaseModel):
    id: int
    client_id: UUID
    full_name: str
    phone: str
    parent_phone: str | None
    note: str | None
    subject_id: int | None
    subject_name: str | None = None
    source: str | None
    stage: str
    lost_reason: str | None
    assigned_to: int | None
    assigned_to_name: str | None = None
    student_id: int | None
    enrollment_id: int | None
    enrolled_at: datetime | None
    closed_at: datetime | None
    preferred_trial_date: date | None
    desired_weekdays: list[int] | None = None
    desired_time_of_day: str | None = None
    level: str | None = None
    group_id: int | None = None
    group_name: str | None = None
    address: str | None = None
    next_trial_at: datetime | None = None
    next_trial_booking_id: int | None = None
    next_task_due_at: datetime | None = None
    last_contact_at: datetime | None = None
    version: int
    created_at: datetime
    updated_at: datetime
    # True when a create was folded into an existing open lead.
    merged: bool = False


class SimilarLead(BaseModel):
    id: int
    full_name: str
    phone: str
    group_name: str | None
    subject_name: str | None
    created_at: datetime


class DuplicateCheck(BaseModel):
    """What the front desk should know before saving someone: a student or an
    open request with this phone, or with exactly this name. A warning only --
    one person may study in several groups, so nothing here blocks a save."""

    phone_student: PhoneOwner | None = None
    phone_leads: list[SimilarLead] = []
    name_students: list[PhoneOwner] = []
    name_leads: list[SimilarLead] = []


class UndoLeadRequest(BaseModel):
    client_id: UUID


class UndoLeadResult(BaseModel):
    undone: bool
    lead: Lead | None = None


class LeadPage(BaseModel):
    items: list[Lead]
    total: int


class PhoneLookup(BaseModel):
    """Everything known about a phone number: the student who has it, if
    any, and every lead made with it -- the "contact" in one place."""

    phone: str
    student: PhoneOwner | None
    leads: list[Lead]


class CreateInteractionRequest(BaseModel):
    kind: str
    body: str


class LeadInteraction(BaseModel):
    id: int
    lead_id: int
    kind: str
    body: str
    old_stage: str | None
    new_stage: str | None
    booking_id: int | None
    task_id: int | None
    created_by: int | None
    created_by_name: str | None = None
    created_at: datetime


class CreateFollowUpTaskRequest(BaseModel):
    lead_id: int
    title: str
    due_at: datetime
    assigned_to: int | None = None


class UpdateFollowUpTaskRequest(BaseModel):
    version: int
    title: str | None = None
    due_at: datetime | None = None
    assigned_to: int | None = None


class FollowUpTask(BaseModel):
    id: int
    lead_id: int
    lead_full_name: str | None = None
    lead_phone: str | None = None
    lead_stage: str | None = None
    title: str
    due_at: datetime
    assigned_to: int | None
    assigned_to_name: str | None = None
    status: str
    completed_at: datetime | None
    version: int
    created_at: datetime


class CreateTrialSessionRequest(BaseModel):
    kind: str = "dedicated"
    subject_id: int | None = None
    group_id: int | None = None
    teacher_id: int | None = None
    room: str | None = None
    starts_at: datetime
    ends_at: datetime
    capacity: int = 1
    note: str | None = None


class UpdateTrialSessionRequest(BaseModel):
    version: int
    teacher_id: int | None = None
    room: str | None = None
    starts_at: datetime | None = None
    ends_at: datetime | None = None
    capacity: int | None = None
    note: str | None = None


class TrialSessionBooking(BaseModel):
    id: int
    lead_id: int
    lead_full_name: str
    lead_phone: str
    status: str
    feedback: str | None


class TrialSession(BaseModel):
    id: int
    kind: str
    subject_id: int | None
    subject_name: str | None = None
    group_id: int | None
    group_name: str | None = None
    teacher_id: int | None
    teacher_name: str | None = None
    room: str | None
    starts_at: datetime
    ends_at: datetime
    capacity: int
    status: str
    note: str | None
    version: int
    # Seats taken: scheduled, attended and absent bookings.
    booked: int = 0
    bookings: list[TrialSessionBooking] = []


class CreateTrialBookingRequest(BaseModel):
    lead_id: int
    # An existing session, or a new one created together with the booking.
    session_id: int | None = None
    session: CreateTrialSessionRequest | None = None
    # Leave a task to remind the client the day before (reminder messages
    # themselves aren't sent by the app yet).
    remind: bool = False


class RescheduleTrialBookingRequest(BaseModel):
    session_id: int | None = None
    session: CreateTrialSessionRequest | None = None
    reason: str | None = None


class TrialAttendanceRequest(BaseModel):
    status: str  # 'attended' | 'absent'


class TrialFeedbackRequest(BaseModel):
    feedback: str
    recommended_level: str | None = None


class CancelRequest(BaseModel):
    reason: str | None = None


class TrialBooking(BaseModel):
    id: int
    lead_id: int
    session_id: int
    status: str
    rescheduled_from_id: int | None
    cancel_reason: str | None
    attendance_marked_at: datetime | None
    feedback: str | None
    recommended_level: str | None
    feedback_at: datetime | None
    version: int
    created_at: datetime
    session: TrialSession | None = None


class LeadDetail(BaseModel):
    lead: Lead
    interactions: list[LeadInteraction]
    bookings: list[TrialBooking]
    tasks: list[FollowUpTask]
    student: PhoneOwner | None


class EnrollLeadRequest(BaseModel):
    """The enrollment wizard's confirmed data. Student fields are used only
    when the lead isn't a student yet; an existing student is reused as-is."""

    full_name: str
    phone: str
    parent_phone: str | None = None
    heard_from: str | None = None
    note: str | None = None
    group_id: int
    joined_at: date
    first_month: str | None = None
    discount_kind: str | None = None
    discount_value: int | None = None
    first_payment_amount: int | None = None
    first_payment_method: str | None = None


class LeadEnrolled(BaseModel):
    lead_id: int
    student: Student
    reused_student: bool
    enrollment_id: int
    first_charge: int
    first_payment: int


class CountByKey(BaseModel):
    key: str
    count: int
    enrolled: int = 0


class AdmissionsReport(BaseModel):
    """Admissions numbers for date_from..date_to, both inclusive, in the
    center's calendar. Every rate is null when its denominator is 0."""

    date_from: date
    date_to: date
    new_inquiries: int
    # Bookings whose lesson falls in the period. A moved trial counts once,
    # at its new time.
    trials_booked: int
    trials_attended: int
    trials_absent: int
    trials_cancelled: int
    # attended / (attended + absent).
    show_rate: float | None
    # Leads enrolled in the period, whenever they first called.
    enrollments: int
    # Cohort: leads created in the period, and how many of those are
    # enrolled by now.
    cohort_size: int
    cohort_enrolled: int
    lead_conversion_rate: float | None
    # Leads with an attended trial in the period, and how many of those are
    # enrolled by now.
    trial_cohort_size: int
    trial_cohort_enrolled: int
    trial_conversion_rate: float | None
    # Right now, not for the period: booked trials in the next 7 days, and
    # open follow-ups past due / due later today.
    upcoming_trials: int
    follow_ups_overdue: int
    follow_ups_due_today: int
    open_by_stage: list[CountByKey]
    cohort_by_source: list[CountByKey]


# Staff accounts --------------------------------------------------------------


class StaffMember(BaseModel):
    id: int
    phone: str
    full_name: str
    role: str
    is_active: bool
    created_at: datetime
    last_login_at: datetime | None = None


class CreateStaffRequest(BaseModel):
    phone: str
    full_name: str
    password: str


class UpdateStaffRequest(BaseModel):
    full_name: str | None = None
    is_active: bool | None = None


class ResetPasswordRequest(BaseModel):
    password: str


# Schedule and attendance ---------------------------------------------------


class ScheduleSlot(BaseModel):
    weekday: int
    starts_at: time
    ends_at: time
    room: str | None = None


class GroupSchedule(BaseModel):
    group_id: int
    slots: list[ScheduleSlot]


class SetGroupScheduleRequest(BaseModel):
    slots: list[ScheduleSlot]


class TimetableLesson(BaseModel):
    """One lesson in the timetable -- from the group's weekly schedule,
    or an extra one. lesson_id is set once it has a row (attendance marked,
    cancelled, or extra)."""

    group_id: int
    group_name: str
    subject_name: str | None
    teacher_id: int | None
    teacher_name: str | None
    room: str | None
    starts_at: datetime
    ends_at: datetime
    lesson_id: int | None = None
    # 'scheduled' | 'cancelled'
    status: str = "scheduled"
    cancel_reason: str | None = None
    is_extra: bool = False
    student_count: int = 0
    marked_count: int = 0
    present_count: int = 0


class SheetStudent(BaseModel):
    enrollment_id: int
    student_id: int
    full_name: str
    phone: str
    status: str | None = None
    note: str | None = None


class SheetTrialGuest(BaseModel):
    booking_id: int
    lead_id: int
    full_name: str
    status: str


class AttendanceSheet(BaseModel):
    lesson: TimetableLesson
    students: list[SheetStudent]
    trial_guests: list[SheetTrialGuest]


class AttendanceMark(BaseModel):
    enrollment_id: int
    status: str
    note: str | None = None


class MarkAttendanceRequest(BaseModel):
    group_id: int
    starts_at: datetime
    marks: list[AttendanceMark]


class LessonRef(BaseModel):
    group_id: int
    starts_at: datetime
    reason: str | None = None


class CreateExtraLessonRequest(BaseModel):
    group_id: int
    starts_at: datetime
    ends_at: datetime
    room: str | None = None
    note: str | None = None


class AttendanceReportRow(BaseModel):
    enrollment_id: int
    student_id: int
    full_name: str
    phone: str
    group_id: int
    group_name: str
    lessons: int
    present: int
    late: int
    absent: int
    excused: int
    # (present + late) / lessons; null with no marked lessons.
    rate: float | None


GroupListItem.model_rebuild()


# Finance (owner only) --------------------------------------------------------


class CreateExpenseRequest(BaseModel):
    category: str
    amount: int
    spent_on: date
    note: str | None = None
    method: str | None = None
    # Salary payouts only.
    teacher_id: int | None = None
    salary_month: date | None = None


class Expense(BaseModel):
    id: int
    category: str
    amount: int
    spent_on: date
    note: str | None
    method: str | None
    teacher_id: int | None
    teacher_name: str | None = None
    salary_month: date | None
    created_by_name: str | None = None
    created_at: datetime
    voided_at: datetime | None
    void_reason: str | None


class VoidExpenseRequest(BaseModel):
    reason: str


class SetSalaryPercentRequest(BaseModel):
    salary_percent: float | None


class SetSalaryRuleRequest(BaseModel):
    """How a teacher or group is paid: 'percent' (with percent), 'fixed'
    (with fixed, so'm a month), or null for no rule of its own."""

    method: str | None = None
    percent: float | None = None
    fixed: int | None = None


class SalaryLine(BaseModel):
    student_id: int | None
    student_name: str
    group_id: int | None
    group_name: str
    collected: int
    percent: float | None
    # 'percent' (a share of payments) or 'fixed' (the fixed monthly amount).
    method: str = "percent"
    share: int


class TeacherSalary(BaseModel):
    """One teacher's month: what their groups' students paid, their share
    of it, and what has been paid out to them for that month."""

    teacher_id: int
    full_name: str
    is_active: bool
    salary_method: str | None = None
    salary_percent: float | None
    salary_fixed: int | None = None
    collected: int
    earned: int
    paid: int
    remaining: int
    # Who paid, how much, and the teacher's share -- one row per student and group.
    lines: list[SalaryLine] = []


class SalaryMonth(BaseModel):
    month: date
    # A closed month is a frozen snapshot ("Oyni yopish").
    closed: bool = False
    teachers: list[TeacherSalary]
    total_earned: int
    total_paid: int
    total_remaining: int


class FinanceMonth(BaseModel):
    month: date
    income: int
    expenses: int
    profit: int
    by_category: dict[str, int]


class FinanceSummary(BaseModel):
    """Income (payments received), expenses (salary payouts included) and
    profit per calendar month, oldest first, ending with the current one;
    plus salaries earned but not yet paid this month."""

    months: list[FinanceMonth]
    salaries_unpaid_this_month: int


# --- Qabul board and shared counts (see app/funnel.py) ----------------------------------------------------


class BoardLead(BaseModel):
    id: int
    full_name: str
    phone: str
    stage: str
    v2_stage: str
    source: str | None
    lost_reason: str | None
    subject_name: str | None
    assigned_to_name: str | None
    created_at: datetime
    enrolled_at: datetime | None
    closed_at: datetime | None
    stage_changed_at: datetime
    next_trial_at: datetime | None
    last_trial_at: datetime | None
    group_name: str | None


class BoardColumn(BaseModel):
    key: str
    label: str
    count: int
    leads: list[BoardLead]


class FunnelKpi(BaseModel):
    """Period figures; every number is defined in app/funnel.py."""

    date_from: date
    date_to: date
    leads: int
    trial_people: int
    joined: int
    rejected: int
    cohort_size: int
    cohort_joined: int
    conversion_rate: float | None


class AdmissionsBoard(BaseModel):
    date_from: date
    date_to: date
    kpi: FunnelKpi
    columns: list[BoardColumn]


class ShellCounts(BaseModel):
    open_leads: int
    active_students: int
    active_groups: int
    active_teachers: int


class StudentSummary(BaseModel):
    active_students: int
    total_students: int
    new_students_this_month: int
    students_with_debt: int


# --- Kurs qidirish and the trial date picker ---------------------------------------------------------------------


class GroupMatch(BaseModel):
    group_id: int
    name: str
    subject_name: str | None
    level: str | None
    teacher_name: str | None
    fee_amount: int
    billing_mode: str
    billing_day: int | None
    prorate_first_period: bool
    start_date: date | None
    capacity: int | None
    enrolled: int
    # Null = no seat limit.
    free_seats: int | None
    slots: list["ScheduleSlot"]
    weekdays: list[int]
    # How many of the group's lesson days the client can come on.
    matched_days: int
    total_days: int


class GroupSearchResult(BaseModel):
    exact: list[GroupMatch]
    near: list[GroupMatch]


class TrialDate(BaseModel):
    """One upcoming lesson of a group a guest could attend as a trial."""

    starts_at: datetime
    ends_at: datetime
    room: str | None
    # An existing guest session for that lesson, if someone is already booked.
    trial_session_id: int | None
    guests_booked: int
    # A guest session exists for this lesson and has no seat left.
    session_full: bool = False
    # Seats left in the group (null = no limit) and the guest seats to open
    # if the session doesn't exist yet.
    free_seats: int | None
    suggested_capacity: int


class ProfileAttendance(BaseModel):
    present: int = 0
    late: int = 0
    absent: int = 0
    excused: int = 0
    # Lessons that were marked for this student, and the share they came to
    # (present or late). Null until a lesson has been marked.
    total: int = 0
    rate: float | None = None
    # The last ten marks, oldest first.
    recent: list[str] = []


class ProfileMark(BaseModel):
    at: datetime
    group_name: str
    status: str


class ProfileGroup(BaseModel):
    enrollment_id: int
    group_id: int
    group_name: str
    subject_name: str | None
    teacher_name: str | None
    fee_amount: int
    joined_at: date
    status: str
    # > 0: the student owes this much on this group (money.enrollment_balances).
    balance: int
    next_due_date: date | None = None
    schedule: list["ScheduleSlot"] = []
    attendance: ProfileAttendance


class ProfilePayment(BaseModel):
    id: int
    enrollment_id: int | None
    group_name: str | None
    amount: int
    method: str | None
    received_at: datetime
    received_by_name: str | None
    receipt_no: str | None
    note: str | None
    status: str
    cancel_reason: str | None = None


class StudentProfile(BaseModel):
    """Everything the profile panel shows, in one answer."""

    student: Student
    is_new: bool
    # > 0: owes this much across every group.
    balance: int
    paid_total: int
    groups: list[ProfileGroup]
    attendance: ProfileAttendance
    payments: list[ProfilePayment]
    # How long the oldest unpaid charge has been due (null = nothing overdue).
    debt_since: date | None = None
    overdue_days: int = 0
    activity: list["ActivityItem"] = []
    # The last thirty marked lessons, newest first -- the Davomat tab.
    marks: list["ProfileMark"] = []


class StudentGroupRef(BaseModel):
    """A group a student is in now, as the table shows it: name, teacher, days."""

    group_id: int
    name: str
    subject_id: int | None = None
    subject_name: str | None = None
    teacher_id: int | None = None
    teacher_name: str | None = None
    schedule: list["ScheduleSlot"] = []


class ActivityItem(BaseModel):
    """One line of "So'nggi faollik" on the profile."""

    at: datetime
    # 'joined' | 'charge' | 'payment' | 'payment_cancelled' | 'absent' | 'late'
    kind: str
    title: str
    detail: str | None = None
    amount: int | None = None


class AddToGroupRequest(BaseModel):
    group_id: int
    joined_at: date
    first_payment_amount: int | None = None
    first_payment_method: str | None = None


class AddedToGroup(BaseModel):
    enrollment_id: int
    group_name: str
    first_charge: int
    first_payment: int


StudentProfile.model_rebuild()
StudentListItem.model_rebuild()


class GroupTeacher(BaseModel):
    id: int
    full_name: str
    phone: str | None = None


class GroupWaiting(BaseModel):
    """Someone who asked for this group in Qabul but is not a student yet: no
    seat, no charge, and not counted in the group's students."""

    lead_id: int
    full_name: str
    phone: str
    created_at: datetime
    trial_at: datetime | None = None


class GroupProfile(BaseModel):
    """A group's profile page in one answer: who teaches it, how full it is,
    who has paid, how they attend, when it meets, when it bills, and how much
    of what was expected has come in."""

    group: Group
    subject_name: str | None
    teacher: GroupTeacher | None
    schedule: list[ScheduleSlot] = []
    # Active students; a full group that took one more simply has more than its capacity.
    student_count: int
    capacity: int | None = None
    free_seats: int | None = None
    # Students who owe nothing on this group / who owe something.
    paid_count: int
    unpaid_count: int
    # Attendance of all this group's marked lessons.
    attendance: ProfileAttendance
    # This billing period: what was charged and what was paid toward it.
    expected: int
    collected: int
    # Everything still unpaid on this group, however old.
    debt_total: int
    # The next billing day (null for a group that bills each student on their own day).
    next_billing_date: date | None = None
    next_lessons: list[datetime] = []
    waiting: list[GroupWaiting] = []
