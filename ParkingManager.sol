// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  ParkingManager — тұрақ орындарын блокчейнде басқару
/// @notice Блокчейн технологиялары, №5–№7 зертханалық жұмыс. Оқу жобасы.
/// @dev    Негізгі объект — Spot. Орын ешқашан жойылмайды, тек күйі өзгереді.
contract ParkingManager {

    /* ───────────────────────── ДЕРЕКТЕР ҚҰРЫЛЫМЫ ───────────────────────── */

    struct Spot {
        uint256 id;            // орын нөмірі, 1-ден басталады
        string  zone;          // аймақ: "A", "B", "C"
        uint256 pricePerHour;  // сағаттық баға, wei
        bool    occupied;      // бос емес күйі
        address driver;        // ағымдағы жүргізуші
        uint256 bookedUntil;   // бронь аяқталатын уақыт, timestamp
    }

    struct Booking {
        uint256 spotId;
        address driver;
        uint256 startAt;
        uint256 hoursCount;    // "hours" — Solidity-де резервтелген сөз
        uint256 amountPaid;    // төленген сома, wei
        bool    active;
    }

    /* ───────────────────────────── MAPPING ─────────────────────────────── */

    address public owner;       // тұрақ иесі (admin)
    uint256 public spotCount;   // тіркелген орын саны

    mapping(uint256 => Spot)      public  spots;        // орынның ағымдағы күйі
    mapping(uint256 => Booking)   public  bookings;     // орындағы соңғы бронь
    mapping(address => bool)      public  isOperator;   // бақылаушы рұқсаты
    mapping(address => uint256[]) private driverSpots;  // жүргізушінің брондары

    /* ───────────────────────────── ОҚИҒАЛАР ────────────────────────────── */

    event SpotAdded(uint256 indexed id, string zone, uint256 pricePerHour);
    event SpotBooked(uint256 indexed id, address indexed driver, uint256 bookedUntil, uint256 amountPaid);
    event SpotReleased(uint256 indexed id, address indexed releasedBy, bool byOperator);
    event OperatorSet(address indexed operator, bool allowed);
    event Withdrawn(address indexed to, uint256 amount);

    /* ───────────────────────────── МОДИФИКАТОР ─────────────────────────── */

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /* ══════════════════════ 1. ҚОСУ (write, owner) ═════════════════════ */

    /// @notice Жаңа тұрақ орнын тіркейді
    function addSpot(string calldata zone, uint256 pricePerHour)
        external onlyOwner returns (uint256)
    {
        return _addSpot(zone, pricePerHour);
    }

    /// @notice Бір аймаққа бірнеше орынды бір транзакциямен қосады
    function addSpots(string calldata zone, uint256 count, uint256 pricePerHour)
        external onlyOwner
    {
        require(count > 0 && count <= 50, "Count must be 1..50");
        for (uint256 i = 0; i < count; i++) {
            _addSpot(zone, pricePerHour);
        }
    }

    function _addSpot(string memory zone, uint256 pricePerHour) internal returns (uint256) {
        require(bytes(zone).length > 0, "Zone required");
        require(pricePerHour > 0, "Price must be above zero");

        spotCount += 1;
        spots[spotCount] = Spot({
            id:           spotCount,
            zone:         zone,
            pricePerHour: pricePerHour,
            occupied:     false,
            driver:       address(0),
            bookedUntil:  0
        });

        emit SpotAdded(spotCount, zone, pricePerHour);
        return spotCount;
    }

    /* ══════════════════════ 2. ӨЗГЕРТУ (write) ═════════════════════════ */

    /// @notice Бос орынды брондайды. Төлем контрактта сақталады.
    function bookSpot(uint256 id, uint256 hoursCount) external payable {
        Spot storage s = spots[id];

        require(s.id != 0,                "Spot not found");       // R1
        require(!s.occupied,              "Spot already booked");  // R2
        require(hoursCount > 0 && hoursCount <= 24, "Hours must be 1..24");
        require(msg.value == s.pricePerHour * hoursCount, "Wrong payment"); // R3

        s.occupied    = true;
        s.driver      = msg.sender;
        s.bookedUntil = block.timestamp + hoursCount * 1 hours;

        bookings[id] = Booking({
            spotId:     id,
            driver:     msg.sender,
            startAt:    block.timestamp,
            hoursCount: hoursCount,
            amountPaid: msg.value,
            active:     true
        });

        driverSpots[msg.sender].push(id);

        emit SpotBooked(id, msg.sender, s.bookedUntil, msg.value);
    }

    /// @notice Орынды босатады. Бронь иесі кез келген уақытта,
    ///         бақылаушы тек мерзімі өткен соң босата алады.
    function releaseSpot(uint256 id) external {
        Spot storage s = spots[id];

        require(s.id != 0,  "Spot not found");
        require(s.occupied, "Spot is already free");

        bool expired    = block.timestamp >= s.bookedUntil;
        bool byDriver   = (s.driver == msg.sender);
        bool byOperator = (isOperator[msg.sender] && expired);

        require(byDriver || byOperator, "Not allowed");            // R4

        s.occupied    = false;
        s.driver      = address(0);
        s.bookedUntil = 0;
        bookings[id].active = false;

        emit SpotReleased(id, msg.sender, byOperator && !byDriver);
    }

    /// @notice Бақылаушы рұқсатын береді немесе алып қояды
    function setOperator(address operatorAddress, bool allowed) external onlyOwner {
        require(operatorAddress != address(0), "Zero address");
        isOperator[operatorAddress] = allowed;
        emit OperatorSet(operatorAddress, allowed);
    }

    /// @notice Жиналған төлемді тұрақ иесі шығарып алады
    /// @dev    checks → effects → interactions реті
    function withdraw() external onlyOwner {
        uint256 amount = address(this).balance;
        require(amount > 0, "Nothing to withdraw");

        emit Withdrawn(owner, amount);

        (bool sent, ) = payable(owner).call{value: amount}("");
        require(sent, "Transfer failed");
    }

    /* ══════════════════════ 3. ОҚУ (view, газсыз) ══════════════════════ */

    /// @notice Бір орын туралы деректерді қайтарады
    function getSpot(uint256 id) external view returns (Spot memory) {
        require(spots[id].id != 0, "Spot not found");
        return spots[id];
    }

    /// @notice Барлық орынды бір сұраумен қайтарады (интерфейс торы үшін)
    function getAllSpots() external view returns (Spot[] memory) {
        Spot[] memory list = new Spot[](spotCount);
        for (uint256 i = 1; i <= spotCount; i++) {
            list[i - 1] = spots[i];
        }
        return list;
    }

    /// @notice Бос орындардың нөмірлерін қайтарады
    function getFreeSpots() external view returns (uint256[] memory) {
        uint256 free = 0;
        for (uint256 i = 1; i <= spotCount; i++) {
            if (!spots[i].occupied) free++;
        }

        uint256[] memory ids = new uint256[](free);
        uint256 k = 0;
        for (uint256 i = 1; i <= spotCount; i++) {
            if (!spots[i].occupied) {
                ids[k] = i;
                k++;
            }
        }
        return ids;
    }

    /// @notice Пайдаланушының брондаған орындарының тарихы
    function getDriverSpots(address driver) external view returns (uint256[] memory) {
        return driverSpots[driver];
    }

    /// @notice Контрактта жиналған сома
    function contractBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
