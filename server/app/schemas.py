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
    due_day: int
    capacity: int | None = None
    note: str | None = None


class UpdateGroupRequest(BaseModel):
    subject_id: int | None = None
    name: str | None = None
    teacher_id: int | None = None
    fee_amount: int | None = None
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
    due_day: int
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


class StudentEnrollment(BaseModel):
    """One row on a student's profile -- the mirror of RosterEntry, joined
    with the group's identity instead."""

    enrollment_id: int
    group_id: int
    group_name: str
    joined_at: date
    status: str
    balance: int


class CreatePaymentRequest(BaseModel):
    amount: int
    note: str | None = None


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
    first_month: str = "prorated"
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
    next_trial_at: datetime | None = None
    next_trial_booking_id: int | None = None
    next_task_due_at: datetime | None = None
    last_contact_at: datetime | None = None
    version: int
    created_at: datetime
    updated_at: datetime
    # True when a create was folded into an existing open lead.
    merged: bool = False


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
    first_month: str = "prorated"
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
