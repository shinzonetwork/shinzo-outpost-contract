// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

contract Outpost {
    // Errors
    error PaymentAmountTooLow(uint256 amount);
    error ResourceDoesNotExist(Resource resource);
    error DigitalIdDoesNotExist(string identity);
    error PaymentAlreadyExpired();
    error PaymentNotExpired();
    error ZeroAddress();
    error Unauthorized();

    // Events
    event PaymentCreated(Resource indexed resource, string identity, string StreamId, uint256 expiration);
    event PaymentExpired(address indexed user, uint256 indexed paymentId);

    enum Resource{
        PRIMITIVE, // 0
        VIEW // 1
    }


    // Payment Receipt 
    struct PaymentReceipt {
        Resource resource;
        uint256 amount;
        uint256 timestamp;
        uint256 expiration;
        bool expired;
    }


    // State Variables
    mapping(address => mapping(uint256 => PaymentReceipt)) public payments;
    mapping(address => uint256) public paymentCount;


    /**
     * @notice Creates a new payment for a given policy and identity.
     * @param resource The resource to be paid for.
     * @param identity The digital identity of the user.
     * @param streamId The ID of the stream.
     * @param expiration The duration in seconds until the payment expires.
     */
    function payment(Resource resource, string memory identity, string memory streamId, uint256 expiration)
        public
        payable
    {
        // Validate inputs
        if (msg.value <= 0) revert PaymentAmountTooLow(msg.value);
        if (resource != Resource.PRIMITIVE && resource != Resource.VIEW) revert ResourceDoesNotExist(resource);
        if (bytes(identity).length == 0) revert DigitalIdDoesNotExist(identity);
        if (bytes(streamId).length == 0) revert DigitalIdDoesNotExist(streamId);

        // // Generate payment ID
        uint256 paymentIndex = paymentCount[msg.sender];

        payments[msg.sender][paymentIndex] = PaymentReceipt({
            resource: resource,
            amount: msg.value,
            timestamp: block.timestamp,
            expiration: block.timestamp + expiration,
            expired: false
        });
        paymentCount[msg.sender]++;

        emit PaymentCreated(resource, identity, streamId, expiration);

    }

    /**
     * @notice Expires a payment for a given user and payment index. 
     * @dev The expiration will be managed by ShinzoHub in production
     * @param user The address of the user who made the payment.
     * @param paymentId The ID of the payment to expire.
     * @return success True if the payment was successfully expired.
     */
    function expirePayment(address user, uint256 paymentId) public returns (bool) {
        if (user == address(0)) revert ZeroAddress();
        PaymentReceipt storage _payment = payments[user][paymentId];
        if (_payment.expired) revert PaymentAlreadyExpired();
        if (block.timestamp < _payment.expiration) revert PaymentNotExpired();

        _payment.expired = true;
        emit PaymentExpired(user, paymentId);
        return true;
    }

    /**
     * @notice Retrieves a payment by user and index.
     * @param user The address of the user.
     * @param paymentId The ID of the payment.
     * @return Payment struct.
     */
    function getPayment(address user, uint256 paymentId) public view returns (PaymentReceipt memory) {
        if (user == address(0)) revert ZeroAddress();
        return payments[user][paymentId];
    }

    /**
     * @notice Retrieves the amount of a payment.
     * @param user The address of the user.
     * @param paymentId The ID of the payment.
     * @return The payment amount.
     */
    function getPaymentAmount(address user, uint256 paymentId) public view returns (uint256) {
        if (user == address(0)) revert ZeroAddress();
        return payments[user][paymentId].amount;
    }

    /**
     * @notice Retrieves the total number of payments for a user.
     * @param user The address of the user.
     * @return The number of payments.
     */
    function getPaymentCount(address user) public view returns (uint256) {
        if (user == address(0)) revert ZeroAddress();
        return paymentCount[user];
    }

    // function withdraw() public {
    //     if (msg.sender != address(0) ) revert Unauthorized();
    //     (bool success, ) = msg.sender.call{value: address(this).balance}("");
    //     require(success);   
    // }

}
